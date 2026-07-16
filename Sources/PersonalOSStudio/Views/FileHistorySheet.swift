import SwiftUI

/// Per-file git history: pick a commit, view that version, and diff it against the
/// current editor buffer.
struct FileHistorySheet: View {
    @ObservedObject var git: GitService
    let relativePath: String
    let currentText: String
    @Environment(\.dismiss) var dismiss

    @State private var commits: [GitService.Commit] = []
    @State private var selected: GitService.Commit?
    @State private var oldText: String?
    @State private var loading = true
    @State private var showDiff = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentColor)
                Text(relativePath).font(.headline.monospaced())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commits.isEmpty {
                Text(git.contentFilesIgnored
                     ? "This file is gitignored as PII — it's intentionally kept out of git, so there's no version history to show."
                     : "No history for this file (not tracked yet — snapshot it first).")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(commits, selection: Binding(get: { selected?.id }, set: { id in
                        selected = commits.first { $0.id == id }
                        Task { await loadVersion() }
                    })) { commit in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(commit.subject).font(.caption).lineLimit(1)
                            Text("\(commit.date.formatted(.relative(presentation: .named))) · \(commit.id.prefix(7))")
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        .tag(commit.id)
                    }
                    .frame(minWidth: 200, maxWidth: 280)

                    VStack(alignment: .leading, spacing: 8) {
                        if let oldText {
                            Picker("", selection: $showDiff) {
                                Text("Diff vs current").tag(true)
                                Text("Full version").tag(false)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            if showDiff {
                                DiffView(old: oldText, new: currentText)
                            } else {
                                ScrollView {
                                    Text(oldText)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
                            }
                        } else {
                            Text("Select a commit to view that version.")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(10)
                    .frame(minWidth: 380)
                }
            }
        }
        .frame(width: 760, height: 520)
        .task {
            commits = await git.history(path: relativePath)
            loading = false
            if let first = commits.first {
                selected = first
                await loadVersion()
            }
        }
    }

    private func loadVersion() async {
        guard let commit = selected else { return }
        oldText = await git.show(commit: commit.id, path: relativePath)
    }
}
