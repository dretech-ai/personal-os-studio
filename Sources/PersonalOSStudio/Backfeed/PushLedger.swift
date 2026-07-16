import Foundation
import CryptoKit

/// Records what Studio pushed to each harness target — relative path → SHA-256 of the
/// pushed bytes + source provenance. The ledger is the baseline that makes harness
/// drift detectable deterministically: current bytes vs recorded hash. Metadata only —
/// hashes and paths, never document content — persisted per-user under Application
/// Support (keyed by harness id + target path), outside any repo.
struct PushLedger {

    struct Entry: Codable, Equatable {
        let sha256: String
        let source: String     // artifact sourceDescription, e.g. "Identity ← identity.md"
    }

    /// v2 manifest: entries + the moment Studio FIRST pushed to this target. The epoch
    /// lets the scanner separate vendor stock (files that predate any Studio push, e.g.
    /// Hermes's bundled skills) from real drift the agent wrote afterwards.
    struct Manifest: Codable {
        var firstPush: Date?
        var entries: [String: Entry]
    }

    /// Injectable for tests; the app uses `.standard`.
    let baseDir: URL

    static let standard = PushLedger(
        baseDir: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PersonalOSStudio/ledger"))

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

    /// Record the full artifact set of a push (including artifacts skipped as
    /// unchanged — they are on disk and part of the baseline). Stamps `firstPush` the
    /// first time a target is recorded (including the upgrade of a legacy manifest).
    func record(harness: String, target: URL, artifacts: [BuildArtifact], now: Date = Date()) {
        var manifest = load(harness: harness, target: target)
        if manifest.firstPush == nil { manifest.firstPush = now }
        for artifact in artifacts {
            manifest.entries[artifact.relativePath] = Entry(
                sha256: Self.sha256(artifact.contents),
                source: artifact.sourceDescription)
        }
        write(manifest, harness: harness, target: target)
    }

    func manifest(harness: String, target: URL) -> [String: Entry] {
        load(harness: harness, target: target).entries
    }

    /// First-push epoch for a target — nil for never-pushed targets and for legacy
    /// (entry-only) manifests that predate the field.
    func firstPush(harness: String, target: URL) -> Date? {
        load(harness: harness, target: target).firstPush
    }

    private func load(harness: String, target: URL) -> Manifest {
        guard let data = try? Data(contentsOf: fileURL(harness: harness, target: target)) else {
            return Manifest(firstPush: nil, entries: [:])
        }
        if let v2 = try? JSONDecoder().decode(Manifest.self, from: data), v2.entries.isEmpty == false || v2.firstPush != nil {
            return v2
        }
        // Legacy format: a bare [path: Entry] dictionary. No epoch → filter inactive
        // until the next record() upgrades it.
        if let legacy = try? JSONDecoder().decode([String: Entry].self, from: data) {
            return Manifest(firstPush: nil, entries: legacy)
        }
        return Manifest(firstPush: nil, entries: [:])
    }

    private func write(_ manifest: Manifest, harness: String, target: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDir.path)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: fileURL(harness: harness, target: target))
        }
    }

    /// One JSON file per (harness, target): harness id + a hash of the target path —
    /// filenames never leak where your harnesses live.
    private func fileURL(harness: String, target: URL) -> URL {
        let key = Self.sha256(target.standardizedFileURL.path).prefix(16)
        return baseDir.appendingPathComponent("\(harness)-\(key).json")
    }
}
