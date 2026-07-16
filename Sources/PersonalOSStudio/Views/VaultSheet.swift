import SwiftUI
import AppKit

/// PII vault management: enable, snapshot now, browse snapshots, restore (with diff
/// confirm), relocate the blob directory, tune retention, export/import the key.
struct VaultSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var vault: VaultService
    @Environment(\.dismiss) var dismiss

    @State private var selected: VaultSnapshot?
    @State private var selectedManifest: PIIVault.Manifest?
    @State private var restoreLog: [String] = []
    @State private var confirmRestoreAll = false
    @State private var confirmRestorePath: String?
    @State private var passphrase = ""
    @State private var keyNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundStyle(Color.accentColor)
                Text("PII Vault").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusSection
                    if vault.enabled {
                        snapshotsSection
                        keySection
                    }
                    if let err = vault.lastError {
                        Label(err, systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if !restoreLog.isEmpty { logView }
                }
                .padding(12)
            }
        }
        .frame(width: 640, height: 560)
        .onAppear { vault.refresh() }
        .confirmationDialog("Restore all \(selected?.fileCount ?? 0) document(s)?",
                            isPresented: $confirmRestoreAll, titleVisibility: .visible) {
            Button("Restore all (overwrites current files)", role: .destructive) {
                if let snap = selected { runRestore(snap, paths: nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Current canonical files are overwritten with the snapshot's versions.")
        }
        .confirmationDialog("Restore \(confirmRestorePath ?? "")?",
                            isPresented: Binding(get: { confirmRestorePath != nil },
                                                 set: { if !$0 { confirmRestorePath = nil } }),
                            titleVisibility: .visible) {
            Button("Restore (overwrites the current file)", role: .destructive) {
                if let snap = selected, let path = confirmRestorePath {
                    runRestore(snap, paths: [path])
                }
                confirmRestorePath = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Status / settings

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Protection")
            Toggle(isOn: $vault.enabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Encrypted snapshots of all content documents")
                    Text("AES-GCM blobs; the key lives only in your macOS Keychain. Complements git — gitignored PII files get history here.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .onChange(of: vault.enabled) { _, on in
                if on {
                    _ = try? vault.ensureKey()
                    vault.snapshotNow(repo: state.store.rootURL, reason: "vault enabled")
                }
            }
            if vault.enabled {
                HStack {
                    Button {
                        vault.snapshotNow(repo: state.store.rootURL, reason: "manual snapshot")
                    } label: {
                        Label("Snapshot now", systemImage: "camera.on.rectangle")
                    }
                    Spacer()
                    Stepper("Keep last \(vault.retention)", value: $vault.retention, in: 5...200, step: 5)
                        .font(.caption)
                }
                HStack(spacing: 6) {
                    Text(vault.vaultDir.path)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Change…") { chooseVaultDir() }.controlSize(.mini)
                }
            }
        }
    }

    // MARK: Snapshots

    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Snapshots (\(vault.snapshots.count))")
            if vault.snapshots.isEmpty {
                Text("No snapshots yet — they're created automatically on every save, and before migration moves.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(vault.snapshots) { snap in
                snapshotRow(snap)
            }
        }
    }

    private func snapshotRow(_ snap: VaultSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                if selected?.id == snap.id {
                    selected = nil; selectedManifest = nil
                } else {
                    selected = snap
                    selectedManifest = try? state.vaultManifest(id: snap.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected?.id == snap.id ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(snap.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption.weight(.medium))
                    Text(snap.reason).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(snap.fileCount) file(s) · \(snap.totalBytes)B")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected?.id == snap.id, let manifest = selectedManifest {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manifest.files.keys.sorted(), id: \.self) { path in
                        fileRow(path: path, bytes: manifest.files[path] ?? Data())
                    }
                    HStack {
                        Spacer()
                        Button {
                            confirmRestoreAll = true
                        } label: {
                            Label("Restore all…", systemImage: "arrow.uturn.backward.circle")
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder
    private func fileRow(path: String, bytes: Data) -> some View {
        let current = (try? String(contentsOf: state.store.rootURL.appendingPathComponent(path),
                                   encoding: .utf8))
        let vaultText = String(data: bytes, encoding: .utf8) ?? ""
        let differs = current != vaultText
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(path).font(.caption2.monospaced())
                if current == nil {
                    Text("missing on disk").font(.caption2).foregroundStyle(.orange)
                } else if !differs {
                    Text("identical").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if current == nil || differs {
                    Button("Restore…") { confirmRestorePath = path }
                        .controlSize(.mini)
                }
            }
            if differs, let current {
                DisclosureGroup("Review diff (current → snapshot)") {
                    DiffView(old: current, new: vaultText)
                        .frame(maxHeight: 180)
                }
                .font(.caption2)
            }
        }
    }

    // MARK: Key recovery

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Key recovery")
            Text("The key lives in your Keychain. Export a passphrase-protected copy for machine migration — losing both means the vault is unrecoverable.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                SecureField("Passphrase for export/import", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Button("Export key…") { exportKey() }
                    .disabled(passphrase.count < 8)
                Button("Import key…") { importKey() }
                    .disabled(passphrase.isEmpty)
            }
            if passphrase.count > 0 && passphrase.count < 8 {
                Text("Use at least 8 characters.").font(.caption2).foregroundStyle(.orange)
            }
            if let notice = keyNotice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func exportKey() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "personal-os-studio.vaultkey"
        panel.message = "Store this file somewhere you trust — it is itself encrypted with your passphrase."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try vault.exportKey(passphrase: passphrase)
            try data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
            keyNotice = "Key exported to \(url.lastPathComponent)."
            passphrase = ""
        } catch {
            keyNotice = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the .vaultkey file exported earlier."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try vault.importKey(data, passphrase: passphrase)
            keyNotice = "Key imported — \(vault.snapshots.count) snapshot(s) readable."
            passphrase = ""
        } catch {
            keyNotice = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: Actions

    private func runRestore(_ snap: VaultSnapshot, paths: [String]?) {
        restoreLog = state.vaultRestore(id: snap.id, paths: paths)
        selectedManifest = try? state.vaultManifest(id: snap.id)
    }

    private func chooseVaultDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Vault blobs are ciphertext-only — a synced or external folder is safe."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vault.vaultDir = url
        vault.refresh()
    }

    // MARK: Bits

    private var logView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(restoreLog, id: \.self) { line in
                Text(line).font(.caption2.monospaced())
                    .foregroundStyle(line.hasPrefix("✗") ? .red : .secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}
