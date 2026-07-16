import Foundation
import Combine

/// Local git awareness for the canonical repo: status, snapshot commits, and per-file
/// history — via the system git binary. **Strictly local**: this service never invokes
/// push / pull / fetch / remote-mutating subcommands; snapshotting your personal OS is
/// wanted, syncing PII to a remote is not (that stays a deliberate terminal action).
@MainActor
final class GitService: ObservableObject {

    struct Commit: Identifiable, Equatable {
        let id: String        // full hash
        let date: Date
        let subject: String
    }

    @Published private(set) var isRepo = false
    /// Repo-relative paths with uncommitted changes (modified, added, untracked, renamed).
    @Published private(set) var dirtyPaths: Set<String> = []
    @Published private(set) var hasRemote = false
    /// True when the repo is git-backed but every filled-in canonical file is gitignored
    /// (the PII posture) — so snapshotting has nothing to act on. Lets the UI explain the
    /// empty state instead of silently hiding all git controls.
    @Published private(set) var contentFilesIgnored = false

    let root: URL

    init(root: URL) {
        self.root = root
    }

    private func git(_ args: [String]) async -> OpenClawService.ProcResult {
        await OpenClawService.run("/usr/bin/git", ["-C", root.path] + args)
    }

    // MARK: State

    func refresh() async {
        let probe = await git(["rev-parse", "--is-inside-work-tree"])
        isRepo = probe.exitCode == 0 && probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard isRepo else { dirtyPaths = []; hasRemote = false; return }

        // -uall lists untracked files individually (default folds them into "dir/").
        let status = await git(["status", "--porcelain=v1", "--untracked-files=all"])
        dirtyPaths = Self.parsePorcelain(status.stdout)

        let remotes = await git(["remote"])
        hasRemote = !remotes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parse `git status --porcelain=v1` into repo-relative paths. Handles renames
    /// (`R  old -> new`, keeps the new path) and quoted paths with escapes.
    nonisolated static func parsePorcelain(_ output: String) -> Set<String> {
        var paths: Set<String> = []
        for line in output.components(separatedBy: "\n") where line.count > 3 {
            let payload = String(line.dropFirst(3))
            let path: String
            if payload.contains(" -> ") {
                path = payload.components(separatedBy: " -> ").last ?? payload
            } else {
                path = payload
            }
            paths.insert(unquote(path))
        }
        return paths
    }

    /// Strip git's C-style quoting (`"path with spaces"` with backslash escapes).
    nonisolated private static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 else { return path }
        let inner = String(path.dropFirst().dropLast())
        return inner
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Recompute `contentFilesIgnored` from the store's real (non-template/example)
    /// files — one `git check-ignore` call. Kept separate from `refresh()` because the
    /// internal callers (e.g. after a commit) don't hold the store.
    func updateContentTracking(store: CanonicalStore) async {
        guard isRepo else { contentFilesIgnored = false; return }
        let contentPaths = Layer.allCases.flatMap { store.files($0) }
            .filter { !$0.isTemplate && !$0.isExample }
            .map { relativePath(of: $0) }
        guard !contentPaths.isEmpty else { contentFilesIgnored = false; return }
        let ignored = await ignoredPaths(contentPaths)
        contentFilesIgnored = ignored.count == contentPaths.count
    }

    /// The subset of the given repo-relative paths that git ignores (via `check-ignore`).
    /// Empty when none are ignored. `check-ignore` prints one line per matched path and
    /// exits 1 when nothing matches, so we parse stdout rather than gate on exit code.
    func ignoredPaths(_ paths: [String]) async -> [String] {
        guard isRepo, !paths.isEmpty else { return [] }
        let result = await git(["check-ignore"] + paths)
        return result.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Repo-relative path of a canonical file (for dirty lookups).
    func relativePath(of file: CanonicalFile) -> String {
        file.url.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    func isDirty(_ file: CanonicalFile) -> Bool {
        dirtyPaths.contains(relativePath(of: file))
    }

    // MARK: Snapshot (add + commit)

    /// Stage the given repo-relative paths and commit. Returns log lines.
    /// Ignored paths are dropped up front (with a log line) instead of letting one
    /// stale entry fail the whole `git add` — e.g. a file that became gitignored
    /// after the caller's list was computed.
    func commit(paths: [String], message: String) async -> [String] {
        guard isRepo, !paths.isEmpty else { return ["✗ nothing to commit"] }
        var log: [String] = []

        let ignored = Set(await ignoredPaths(paths))
        let stageable = paths.filter { !ignored.contains($0) }
        if !ignored.isEmpty {
            log.append("· skipped \(ignored.count) gitignored file(s)")
        }
        guard !stageable.isEmpty else {
            return log + ["✗ nothing to commit — all selected files are gitignored"]
        }

        let add = await git(["add", "--"] + stageable)
        guard add.exitCode == 0 else {
            return log + ["✗ git add failed: \(add.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"]
        }
        log.append("✓ staged \(stageable.count) file(s)")

        let commit = await git(["commit", "-m", message])
        if commit.exitCode == 0 {
            let hash = await git(["rev-parse", "--short", "HEAD"])
            log.append("✓ committed \(hash.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) — \(message)")
        } else {
            let err = (commit.stderr + commit.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            log.append("✗ git commit failed: \(err)")
        }
        await refresh()
        return log
    }

    // MARK: History

    func history(path: String) async -> [Commit] {
        guard isRepo else { return [] }
        let result = await git(["log", "--follow", "--format=%H%x09%ct%x09%s", "--", path])
        guard result.exitCode == 0 else { return [] }
        return result.stdout.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, let epoch = TimeInterval(parts[1]) else { return nil }
            return Commit(id: parts[0], date: Date(timeIntervalSince1970: epoch),
                          subject: parts[2...].joined(separator: "\t"))
        }
    }

    func show(commit: String, path: String) async -> String? {
        guard isRepo else { return nil }
        let result = await git(["show", "\(commit):\(path)"])
        return result.exitCode == 0 ? result.stdout : nil
    }

    /// PII-sync advisory: the repo has a remote and canonical PII files are tracked.
    func piiRemoteAdvisory(store: CanonicalStore) -> String? {
        guard isRepo, hasRemote else { return nil }
        let hasPII = Layer.allCases.flatMap { store.files($0) }
            .contains { !$0.isTemplate && !$0.isExample && $0.designation == .pii }
        guard hasPII else { return nil }
        return "This repo has a remote. Canonical PII files should not be pushed to shared remotes — Studio only ever commits locally."
    }
}
