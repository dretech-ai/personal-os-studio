import SwiftUI

/// "Snapshot changes" — stage-and-commit uncommitted canonical edits from inside
/// Studio. Local only: Studio never pushes.
struct SnapshotSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var git: GitService
    @Environment(\.dismiss) var dismiss

    @State private var checked: Set<String> = []
    @State private var message = ""
    @State private var log: [String] = []
    @State private var committing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "camera.on.rectangle").foregroundStyle(Color.accentColor)
                Text("Snapshot changes").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            if let advisory = git.piiRemoteAdvisory(store: state.store) {
                Label(advisory, systemImage: "exclamationmark.shield.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            }

            if git.dirtyPaths.isEmpty {
                Label("Working tree clean — nothing to snapshot.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("\(git.dirtyPaths.count) file(s) with uncommitted changes:")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(git.dirtyPaths.sorted(), id: \.self) { path in
                            Toggle(isOn: Binding(
                                get: { checked.contains(path) },
                                set: { on in if on { checked.insert(path) } else { checked.remove(path) } })) {
                                Text(path).font(.caption.monospaced())
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 180)

                TextField("Commit message", text: $message)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button {
                        Task {
                            committing = true
                            log = await git.commit(paths: Array(checked), message: message)
                            committing = false
                        }
                    } label: {
                        Label(committing ? "Committing…" : "Commit \(checked.count) file(s)",
                              systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(committing || checked.isEmpty || message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !log.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(log, id: \.self) { line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(line.hasPrefix("✗") ? .red : .secondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
            }
        }
        .padding(16)
        .frame(width: 520)
        .task {
            // Re-scan before listing: a .gitignore edit (or any outside-app change)
            // since the last refresh must not leave stale — possibly now-ignored —
            // paths in the checklist.
            await git.refresh()
            checked = git.dirtyPaths
            message = Self.defaultMessage(for: git.dirtyPaths)
        }
    }

    static func defaultMessage(for paths: Set<String>) -> String {
        let names = paths.sorted().map { ($0 as NSString).lastPathComponent }
        let shown = names.prefix(3).joined(separator: ", ")
        let extra = names.count > 3 ? " (+\(names.count - 3) more)" : ""
        return names.isEmpty ? "" : "Update \(shown)\(extra)"
    }
}
