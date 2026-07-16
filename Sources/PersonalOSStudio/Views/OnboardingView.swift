import SwiftUI
import AppKit

/// First-run onboarding / repo picker: choose an existing canonical Agent OS repo or
/// scaffold a fresh one. Also reachable any time from the sidebar's Source repo row.
struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    @State private var chosenPath: String = ""
    @State private var scaffoldLog: [String] = []
    @State private var errorMessage: String?
    @State private var newRepoName = "agent_os"
    // Migration step: set when switching to a different valid repo while the current
    // one holds content documents. Offers to bring them across (copy, or move).
    @State private var pendingMigration: (source: URL, dest: URL, count: Int)?
    @State private var migrateMove = false
    @State private var confirmMove = false

    private var chosenValid: Bool {
        guard !chosenPath.isEmpty else { return false }
        return FileManager.default.fileExists(
            atPath: (chosenPath as NSString).appendingPathComponent("adapters"))
    }

    var body: some View {
        if let m = pendingMigration {
            migrationStep(m)
        } else {
            pickerBody
        }
    }

    private var pickerBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "shippingbox").foregroundStyle(Color.accentColor).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose your canonical repo").font(.headline)
                    Text("Your personal OS lives in one canonical Agent OS repo — Markdown layers (Identity, Context, Skills, Memory) that Studio edits, validates, and trains harnesses from. Harness workspaces (like OpenClaw's) are separate render targets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.store.isValidRoot {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }

            Divider()

            // Path A: choose an existing repo.
            VStack(alignment: .leading, spacing: 6) {
                Text("Use an existing repo").font(.subheadline.weight(.semibold))
                HStack {
                    TextField("path to agent_os checkout", text: $chosenPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                    Button("Browse…") { browseExisting() }
                }
                if !chosenPath.isEmpty {
                    Label(chosenValid ? "Valid Agent OS repo." : "Not a valid Agent OS repo (no adapters/ directory).",
                          systemImage: chosenValid ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(chosenValid ? .green : .red)
                }
                Button {
                    useExisting()
                } label: {
                    Label("Use this repo", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!chosenValid)
            }

            Divider()

            // Path B: scaffold a fresh repo.
            VStack(alignment: .leading, spacing: 6) {
                Text("Or create a new one").font(.subheadline.weight(.semibold))
                Text("Creates the layer directories, authoring templates, a PII-safe .gitignore, and initializes git. No sample data — you author content via the Interview.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    TextField("repo folder name", text: $newRepoName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Button {
                        createNew()
                    } label: {
                        Label("Create in folder…", systemImage: "plus.square.on.square")
                    }
                    .disabled(newRepoName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if !scaffoldLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(scaffoldLog, id: \.self) { line in
                        Text(line).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 560, height: 430)
        .onAppear {
            if state.store.isValidRoot { chosenPath = state.store.rootURL.path }
        }
    }

    // MARK: Actions

    private func browseExisting() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose your canonical Agent OS repo (the folder containing identity/, adapters/, …)"
        if panel.runModal() == .OK, let url = panel.url {
            chosenPath = url.path
        }
    }

    private func useExisting() {
        let url = URL(fileURLWithPath: (chosenPath as NSString).expandingTildeInPath)
        // Offer to bring existing content across when switching to a *different* repo.
        if state.store.isValidRoot,
           state.store.rootURL.standardizedFileURL != url.standardizedFileURL {
            let count = Migrator.contentFileCount(in: state.store.rootURL)
            if count > 0 {
                pendingMigration = (state.store.rootURL, url, count)
                migrateMove = false
                return
            }
        }
        state.setCanonicalRoot(url)
        dismiss()
    }

    // MARK: Migration step

    private func migrationStep(_ m: (source: URL, dest: URL, count: Int)) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.right.doc.on.clipboard").foregroundStyle(Color.accentColor).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bring your documents across?").font(.headline)
                    Text("**\(m.source.lastPathComponent)** has \(m.count) content document(s). Copy them into **\(m.dest.lastPathComponent)** as part of the switch. Templates already exist in the destination — only your filled-in files transfer.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Toggle(isOn: $migrateMove) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Move (remove the originals from \(m.source.lastPathComponent))")
                    Text("Off = copy (originals stay). On = delete each original after its copy is verified — you'll confirm first.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Skip — just switch") {
                    state.setCanonicalRoot(m.dest)
                    pendingMigration = nil
                    dismiss()
                }
                Spacer()
                Button("Back") { pendingMigration = nil }
                Button(migrateMove ? "Move & switch" : "Copy & switch") {
                    if migrateMove { confirmMove = true } else { runMigration(m, move: false) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 560, height: 300)
        .confirmationDialog("Delete \(m.count) original document(s) from \(m.source.lastPathComponent)?",
                            isPresented: $confirmMove, titleVisibility: .visible) {
            Button("Move (copy, then delete originals)", role: .destructive) { runMigration(m, move: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each original is deleted only after its copy is verified in \(m.dest.lastPathComponent). This cannot be undone.")
        }
    }

    private func runMigration(_ m: (source: URL, dest: URL, count: Int), move: Bool) {
        do {
            // A move deletes originals — take a vault snapshot of the source first so
            // the deletion is reversible. If the vault is on and the snapshot fails,
            // abort rather than proceed without the recovery point.
            if move && state.vault.enabled {
                guard state.vault.snapshotNow(repo: m.source, reason: "pre-move migration") else {
                    errorMessage = "Pre-move vault snapshot failed — move aborted (nothing was changed)."
                    return
                }
            }
            _ = try Migrator.migrate(from: m.source, to: m.dest, move: move)
            errorMessage = nil
            state.setCanonicalRoot(m.dest)
            pendingMigration = nil
            dismiss()
        } catch {
            errorMessage = "Migration failed: \(error.localizedDescription)"
        }
    }

    private func createNew() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create here"
        panel.message = "Choose the parent folder for the new canonical repo"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let root = parent.appendingPathComponent(newRepoName.trimmingCharacters(in: .whitespaces))
        do {
            // Copy templates from the current repo when it's valid; else embedded set.
            let source = state.store.isValidRoot ? state.store.rootURL : nil
            var log = try Scaffold.create(at: root, copyingTemplatesFrom: source)
            errorMessage = nil
            Task {
                log.append(await Scaffold.gitInit(at: root))
                scaffoldLog = log
                state.setCanonicalRoot(root)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
