import Foundation

/// One harness file that changed since Studio's last push to that target.
struct DriftItem: Identifiable, Equatable {
    enum Kind: String { case added, modified }
    let relativePath: String
    let kind: Kind
    let currentText: String
    /// SHA-256 of the current bytes — the dismissal key: rejecting a proposal
    /// suppresses this exact content from being re-proposed.
    let contentHash: String

    var id: String { relativePath }
}

/// What a harvest scan found: real drift, plus how much vendor stock it skipped
/// (reported, never silent).
struct HarvestResult {
    let items: [DriftItem]
    /// Added-file candidates whose creation date predates Studio's first push to the
    /// target — pre-existing vendor content (e.g. Hermes's bundled skills), not drift.
    let preexistingSkipped: Int

    static let empty = HarvestResult(items: [], preexistingSkipped: 0)
}

/// Deterministic drift detection against a push ledger. Strictly read-only on the
/// harness target; no LLM anywhere in this stage.
enum HarvestScanner {

    /// Classify drift in `target` against `manifest`:
    /// - **modified** — a pushed file whose current bytes hash differently
    /// - **added** — a Markdown file inside a pushed directory root that was never
    ///   pushed — unless it was created before `firstPush` (vendor stock → counted in
    ///   `preexistingSkipped` instead; `firstPush == nil` disables the filter).
    ///
    /// Scanning is bounded to what Studio itself pushed: ledger-listed files, plus
    /// recursive walks of only the directory roots that appear in ledger paths (e.g.
    /// `memories/`, `skills/`). A Codex repo target is therefore never trawled — only
    /// its pushed artifacts are examined. `.bak-studio`, hidden files, and non-Markdown
    /// are ignored.
    static func scan(target: URL, manifest: [String: PushLedger.Entry],
                     firstPush: Date? = nil) -> HarvestResult {
        guard !manifest.isEmpty else { return .empty }
        let fm = FileManager.default
        var items: [DriftItem] = []
        var preexisting = 0

        // Modified: every pushed file, compared by hash. (Deleted files are not
        // drift — the next push simply rewrites them.)
        for (rel, entry) in manifest {
            let url = target.appendingPathComponent(rel)
            guard let data = try? Data(contentsOf: url) else { continue }
            let hash = PushLedger.sha256(data)
            if hash != entry.sha256, let text = String(data: data, encoding: .utf8) {
                items.append(DriftItem(relativePath: rel, kind: .modified,
                                       currentText: text, contentHash: hash))
            }
        }

        // Added: walk only directory roots that Studio pushed into.
        let pushedDirRoots = Set(manifest.keys.compactMap { key -> String? in
            let parts = key.components(separatedBy: "/")
            return parts.count > 1 ? parts[0] : nil
        })
        for root in pushedDirRoots.sorted() {
            let rootURL = target.appendingPathComponent(root)
            // Resolve symlinks on BOTH sides before prefix-stripping (e.g. the
            // enumerator yields /private/tmp/… for a /tmp/… root).
            let rootPath = rootURL.resolvingSymlinksInPath().path
            guard let walker = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard url.pathExtension == "md",
                      !url.lastPathComponent.contains(".bak-studio") else { continue }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(rootPath + "/") else { continue }
                let rel = root + "/" + String(path.dropFirst(rootPath.count + 1))
                guard manifest[rel] == nil else { continue }   // pushed → handled above
                // Vendor stock: created before Studio ever pushed here → not drift.
                if let firstPush,
                   let created = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date,
                   created < firstPush {
                    preexisting += 1
                    continue
                }
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else { continue }
                items.append(DriftItem(relativePath: rel, kind: .added,
                                       currentText: text, contentHash: PushLedger.sha256(data)))
            }
        }

        return HarvestResult(items: items.sorted { $0.relativePath < $1.relativePath },
                             preexistingSkipped: preexisting)
    }
}
