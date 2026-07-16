import Foundation
import CryptoKit

/// One restorable point-in-time snapshot in the vault (decrypted header view).
struct VaultSnapshot: Identifiable, Equatable {
    let id: String            // blob filename stem, timestamp-sortable
    let date: Date
    let reason: String
    let fileCount: Int
    let totalBytes: Int
}

/// Encrypted, versioned snapshots of canonical content documents. Complements the
/// PII git posture: the gitignored files get history here, as ciphertext-only blobs
/// (AES-GCM, one sealed manifest per snapshot). Nothing in the vault directory —
/// filenames included — leaks document names or content. Pure logic: keys, clocks,
/// and directories are injected, so everything is testable without Keychain or UI.
enum PIIVault {

    struct Manifest: Codable {
        let version: Int
        let date: Date
        let reason: String
        /// layer-relative path → file bytes
        let files: [String: Data]
    }

    static let blobExtension = "vault"

    // MARK: Sealing

    static func seal(_ manifest: Manifest, key: SymmetricKey) throws -> Data {
        let plain = try JSONEncoder().encode(manifest)
        return try AES.GCM.seal(plain, using: key).combined!
    }

    static func unseal(_ data: Data, key: SymmetricKey) throws -> Manifest {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else {
            throw VaultError.corrupt("cannot decrypt blob (wrong key?)")
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: plain) else {
            throw VaultError.corrupt("blob decrypted but manifest unreadable")
        }
        return manifest
    }

    // MARK: Snapshot

    /// Snapshot every content document of `repo` into `vaultDir`. Atomic (temp +
    /// rename); dir 700, blob 600. Returns the new snapshot id.
    @discardableResult
    static func snapshot(repo: URL, into vaultDir: URL, key: SymmetricKey,
                         reason: String, now: Date = Date()) throws -> String {
        let rels = Migrator.contentFiles(in: repo)
        guard !rels.isEmpty else { throw VaultError.nothingToSnapshot }

        var files: [String: Data] = [:]
        for rel in rels {
            files[rel] = try Data(contentsOf: repo.appendingPathComponent(rel))
        }
        let manifest = Manifest(version: 1, date: now, reason: reason, files: files)
        let sealed = try seal(manifest, key: key)

        let fm = FileManager.default
        try fm.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vaultDir.path)

        // Timestamp id; suffix on same-second collision so ids stay unique + sortable.
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        df.timeZone = TimeZone(identifier: "UTC")
        var id = df.string(from: now)
        var n = 1
        while fm.fileExists(atPath: blobURL(id: id, in: vaultDir).path) {
            n += 1
            id = df.string(from: now) + "-\(n)"
        }

        let tmp = vaultDir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try sealed.write(to: tmp)
        try fm.moveItem(at: tmp, to: blobURL(id: id, in: vaultDir))
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: blobURL(id: id, in: vaultDir).path)
        return id
    }

    // MARK: List / read

    static func blobURL(id: String, in vaultDir: URL) -> URL {
        vaultDir.appendingPathComponent("\(id).\(blobExtension)")
    }

    /// All decryptable snapshots, newest first. Unreadable blobs (wrong key, partial
    /// writes that survived a crash) are skipped, never fatal.
    static func list(vaultDir: URL, key: SymmetricKey) -> [VaultSnapshot] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: vaultDir.path) else { return [] }
        var out: [VaultSnapshot] = []
        for entry in entries where entry.hasSuffix(".\(blobExtension)") {
            let id = String(entry.dropLast(blobExtension.count + 1))
            guard let data = try? Data(contentsOf: vaultDir.appendingPathComponent(entry)),
                  let manifest = try? unseal(data, key: key) else { continue }
            out.append(VaultSnapshot(
                id: id, date: manifest.date, reason: manifest.reason,
                fileCount: manifest.files.count,
                totalBytes: manifest.files.values.reduce(0) { $0 + $1.count }))
        }
        return out.sorted { $0.id > $1.id }
    }

    static func manifest(id: String, vaultDir: URL, key: SymmetricKey) throws -> Manifest {
        let data = try Data(contentsOf: blobURL(id: id, in: vaultDir))
        return try unseal(data, key: key)
    }

    // MARK: Restore

    /// Restore documents from snapshot `id` into `repo`. `paths` nil = all files.
    /// Returns log lines.
    @discardableResult
    static func restore(id: String, paths: [String]? = nil, vaultDir: URL,
                        key: SymmetricKey, into repo: URL) throws -> [String] {
        let m = try manifest(id: id, vaultDir: vaultDir, key: key)
        let wanted = paths ?? Array(m.files.keys)
        let fm = FileManager.default
        var log: [String] = []
        for rel in wanted.sorted() {
            guard let bytes = m.files[rel] else {
                log.append("✗ \(rel) not in snapshot")
                continue
            }
            let dst = repo.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try bytes.write(to: dst)
            log.append("✓ restored \(rel) (\(bytes.count)B)")
        }
        return log
    }

    // MARK: Prune

    /// Keep the newest `keep` snapshots, delete the rest. Never removes the newest.
    /// Returns how many were deleted.
    @discardableResult
    static func prune(vaultDir: URL, key: SymmetricKey, keep: Int) -> Int {
        guard keep > 0 else { return 0 }
        let all = list(vaultDir: vaultDir, key: key)   // newest first
        guard all.count > keep else { return 0 }
        var removed = 0
        for snap in all.dropFirst(keep) {
            if (try? FileManager.default.removeItem(at: blobURL(id: snap.id, in: vaultDir))) != nil {
                removed += 1
            }
        }
        return removed
    }
}

// MARK: - App-facing service

/// Owns vault settings (enabled / location / retention), the Keychain key, and the
/// debounced auto-snapshot pipeline. All GUI paths go through here; headless tests
/// use PIIVault/VaultKeyExport directly with injected keys.
@MainActor
final class VaultService: ObservableObject {

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "vault.enabled") }
    }
    @Published private(set) var snapshots: [VaultSnapshot] = []
    @Published private(set) var lastError: String?

    /// Blob directory — relocatable; defaults under Application Support.
    @Published var vaultDir: URL {
        didSet { UserDefaults.standard.set(vaultDir.path, forKey: "vault.dir") }
    }
    @Published var retention: Int {
        didSet { UserDefaults.standard.set(retention, forKey: "vault.retention") }
    }

    private let keyStore: VaultKeyStore
    private var pendingAuto: Task<Void, Never>?
    /// Per-launch cache: the Keychain is read at most once per session. Without this,
    /// every refresh/snapshot pair re-triggers the macOS keychain prompt — and with
    /// ad-hoc signing (new signature per rebuild) "Always Allow" doesn't persist, so
    /// redundant reads mean redundant prompts.
    private var cachedKey: SymmetricKey?

    var lastSnapshotDate: Date? { snapshots.first?.date }

    init(keyStore: VaultKeyStore = KeychainVaultKeyStore()) {
        self.keyStore = keyStore
        self.enabled = UserDefaults.standard.bool(forKey: "vault.enabled")
        self.retention = UserDefaults.standard.object(forKey: "vault.retention") as? Int ?? 30
        let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
            .appendingPathComponent("PersonalOSStudio/vault")
        if let saved = UserDefaults.standard.string(forKey: "vault.dir") {
            self.vaultDir = URL(fileURLWithPath: saved)
        } else {
            self.vaultDir = defaultDir
        }
        if enabled { refresh() }
    }

    /// The cached key, reading the Keychain only on first use this session.
    private func loadKey() -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        cachedKey = keyStore.load()
        return cachedKey
    }

    /// The vault key — created and stored in the Keychain on first use.
    func ensureKey() throws -> SymmetricKey {
        if let key = loadKey() { return key }
        let key = SymmetricKey(size: .bits256)
        try keyStore.save(key)
        cachedKey = key
        return key
    }

    var keyAvailable: Bool { loadKey() != nil }

    func refresh() {
        guard enabled, let key = loadKey() else { snapshots = []; return }
        snapshots = PIIVault.list(vaultDir: vaultDir, key: key)
    }

    /// Immediate snapshot. Returns true on success (also on "nothing to snapshot").
    @discardableResult
    func snapshotNow(repo: URL, reason: String) -> Bool {
        guard enabled else { return false }
        do {
            let key = try ensureKey()
            try PIIVault.snapshot(repo: repo, into: vaultDir, key: key, reason: reason)
            PIIVault.prune(vaultDir: vaultDir, key: key, keep: retention)
            lastError = nil
            refresh()
            return true
        } catch VaultError.nothingToSnapshot {
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Debounced auto-snapshot: a burst of saves yields one snapshot (~2s quiet).
    func autoSnapshot(repo: URL, reason: String) {
        guard enabled else { return }
        pendingAuto?.cancel()
        pendingAuto = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.snapshotNow(repo: repo, reason: reason)
        }
    }

    // MARK: Key recovery

    func exportKey(passphrase: String) throws -> Data {
        try VaultKeyExport.wrap(key: ensureKey(), passphrase: passphrase)
    }

    func importKey(_ data: Data, passphrase: String) throws {
        let key = try VaultKeyExport.unwrap(data, passphrase: passphrase)
        try keyStore.save(key)
        cachedKey = key
        refresh()
    }
}
