import Foundation

/// Moves or copies canonical CONTENT documents — the filled-in layer files, not
/// templates or examples — from one Agent OS repo into another, preserving each file's
/// layer-relative path. Templates already live in the destination (it was scaffolded),
/// so only real content transfers. A `move` deletes each source file, but only after
/// its copy is verified on disk (never a delete-before-copy).
enum Migrator {

    /// Repo-relative paths of a repo's content documents (excludes templates/examples).
    /// Resolves symlinks on both the root and each file so the prefix strip is reliable
    /// (e.g. /tmp vs /private/tmp), and never emits an absolute path.
    static func contentFiles(in root: URL) -> [String] {
        let store = CanonicalStore(rootURL: root)   // examples excluded by default
        let rootPath = root.resolvingSymlinksInPath().path
        var rels: [String] = []
        for layer in Layer.allCases {
            for f in store.files(layer) where !f.isTemplate && !f.isExample {
                let p = f.url.resolvingSymlinksInPath().path
                if p.hasPrefix(rootPath + "/") {
                    rels.append(String(p.dropFirst(rootPath.count + 1)))
                }
            }
        }
        return rels
    }

    static func contentFileCount(in root: URL) -> Int { contentFiles(in: root).count }

    /// Copy (or move) content documents from `source` into `dest`, preserving relative
    /// paths. Returns log lines. Throws on the first copy failure (before any delete).
    @discardableResult
    static func migrate(from source: URL, to dest: URL, move: Bool) throws -> [String] {
        let fm = FileManager.default
        let rels = contentFiles(in: source)
        var log: [String] = []
        var done = 0
        for rel in rels {
            let src = source.appendingPathComponent(rel)
            let dst = dest.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            // Delete the original only once the copy is confirmed present.
            if move, fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: src)
            }
            done += 1
        }
        log.append("\(move ? "✓ moved" : "✓ copied") \(done) document(s) → \(dest.lastPathComponent)")
        if move { log.append("· originals removed from \(source.lastPathComponent)") }
        return log
    }
}
