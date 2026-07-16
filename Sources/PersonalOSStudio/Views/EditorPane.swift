import SwiftUI

/// Center pane: view / edit the selected canonical file.
struct EditorPane: View {
    @EnvironmentObject var state: AppState
    @State private var text: String = ""
    @State private var loadedFileID: String?
    @State private var dirty = false
    @State private var savedFlash = false
    @State private var showRefine = false
    @State private var showHistory = false
    @State private var showBumpPrompt = false
    @State private var bumpSummary = ""
    @State private var suggestedVersion: SemVer?
    @State private var pendingSaveFile: CanonicalFile?

    var body: some View {
        VStack(spacing: 0) {
            if let file = state.selectedFile {
                header(file)
                findingsStrip(file)
                Divider()
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: text) { _, _ in
                        if loadedFileID == file.id { dirty = true }
                    }
                    .padding(4)
            } else {
                emptyState
            }
        }
        .onChange(of: state.selectedFile?.id) { _, _ in loadSelected() }
        .onAppear { loadSelected() }
        .sheet(isPresented: $showRefine, onDismiss: { loadSelected() }) {
            InterviewView(engine: state.interview, settings: state.settings)
                .environmentObject(state)
        }
        .sheet(isPresented: $showBumpPrompt) { bumpSheet }
        .sheet(isPresented: $showHistory) {
            if let file = state.selectedFile {
                FileHistorySheet(git: state.git,
                                 relativePath: state.git.relativePath(of: file),
                                 currentText: text)
            }
        }
    }

    func header(_ file: CanonicalFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: file.layer.symbol).foregroundStyle(Color.accentColor)
                Text(file.filename).font(.headline)
                DesignationTag(designation: file.designation)
                Spacer()
                if savedFlash {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                if state.git.isRepo && !file.isExample {
                    Button {
                        showHistory = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .help("View this file's git history and diff old versions")
                }
                if !file.isTemplate && !file.isExample {
                    Button {
                        state.pendingRefineFile = file
                        showRefine = true
                    } label: {
                        Label("Refine", systemImage: "wand.and.rays")
                    }
                    .help("Update this doc through a delta interview (bumps version + Change Log)")
                }
                Button {
                    save(file)
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!dirty || file.isExample)
                .help(file.isExample ? "Examples are read-only samples" : "Save changes to disk")
            }
            HStack(spacing: 10) {
                metaChip("v\(file.version)")
                metaChip(file.status)
                metaChip(file.kindBadge)
                Text(file.url.path)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// Collapsible validation findings for the selected file (from the checklists).
    @ViewBuilder
    func findingsStrip(_ file: CanonicalFile) -> some View {
        let findings = state.findings(for: file)
        if !findings.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(findings) { f in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: f.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(f.severity == .error ? .red : .orange)
                                .font(.caption2)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(f.rule).font(.caption2.weight(.semibold).monospaced())
                                Text(f.message).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                let errors = findings.filter { $0.severity == .error }.count
                let warnings = findings.count - errors
                Label(
                    [errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : nil,
                     warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil]
                        .compactMap { $0 }.joined(separator: " · "),
                    systemImage: errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(errors > 0 ? .red : .orange)
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
    }

    func metaChip(_ s: String) -> some View {
        Text(s).font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
            Text("Select a file to view or edit").foregroundStyle(.secondary)
            Text("This is your canonical source — one copy, tool-neutral. The adapter turns it into OpenClaw workspace files on the right.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func loadSelected() {
        guard let file = state.selectedFile else { text = ""; loadedFileID = nil; return }
        text = state.store.read(file)
        loadedFileID = file.id
        dirty = false
        savedFlash = false
    }

    func save(_ file: CanonicalFile) {
        // Hand-edit with an unbumped version → offer a bump + Change Log entry first.
        let original = state.store.read(file)
        if Versioning.needsBumpPrompt(old: original, new: text),
           let current = SemVer(Frontmatter.fields(of: original)["version"] ?? "") {
            suggestedVersion = current.bumped(Versioning.suggestBump(old: original, new: text))
            bumpSummary = ""
            pendingSaveFile = file
            showBumpPrompt = true
            return
        }
        write(text, to: file)
    }

    private func write(_ contents: String, to file: CanonicalFile) {
        do {
            try state.store.write(contents, to: file)
            text = contents
            dirty = false
            savedFlash = true
            state.buildResult = nil   // invalidate any prior build
            state.revalidate()        // re-lint immediately (no full store reload on save)
            state.vaultAutoSnapshot(reason: "editor save")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { savedFlash = false }
        } catch {
            NSSound.beep()
        }
    }

    /// Non-blocking bump offer: accept → version + last_reviewed + Change Log entry
    /// are rewritten surgically; decline → save exactly what's in the buffer.
    private var bumpSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version bump?").font(.headline)
            Text("The content changed but the version didn't. Bump to v\(suggestedVersion?.description ?? "?") and add a Change Log entry?")
                .font(.caption).foregroundStyle(.secondary)
            TextField("One-line change summary", text: $bumpSummary)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Save without bump") {
                    if let file = pendingSaveFile { write(text, to: file) }
                    showBumpPrompt = false
                }
                Button("Bump & save") {
                    if let file = pendingSaveFile, let version = suggestedVersion {
                        let today = Self.today()
                        let summary = bumpSummary.trimmingCharacters(in: .whitespaces)
                        let bumped = Versioning.applyBump(
                            to: text, newVersion: version, today: today,
                            summary: summary.isEmpty ? "hand-edited in Studio" : summary)
                        write(bumped, to: file)
                    }
                    showBumpPrompt = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    private static func today() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        return df.string(from: Date())
    }
}
