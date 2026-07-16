import Foundation

/// Generic artifact writer for directory-delivered harnesses: writes each artifact
/// under a root directory, backing up existing files to `.bak-studio` once per push.
/// Extracted from the original OpenClaw push path so every harness shares one write
/// implementation (and one log format).
enum DirectoryPusher {

    /// Write all artifacts under `root`. Returns the push log.
    @discardableResult
    static func push(_ result: BuildResult, into root: URL, backup: Bool) -> [String] {
        let fm = FileManager.default
        var log: [String] = []
        log.append("→ Target: \(root.path)")

        for artifact in result.artifacts {
            let dest = root.appendingPathComponent(artifact.relativePath)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if backup, fm.fileExists(atPath: dest.path) {
                    let bak = dest.appendingPathExtension("bak-studio")
                    try? fm.removeItem(at: bak)
                    try? fm.copyItem(at: dest, to: bak)
                }
                try artifact.contents.write(to: dest, atomically: true, encoding: .utf8)
                log.append("✓ wrote \(artifact.relativePath) (\(artifact.byteCount) bytes)")
            } catch {
                log.append("✗ FAILED \(artifact.relativePath): \(error.localizedDescription)")
            }
        }
        log.append("Done: \(result.artifacts.count) file(s).")
        return log
    }
}
