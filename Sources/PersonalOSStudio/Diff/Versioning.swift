import Foundation

/// Version-management helpers for hand-edits: bump suggestion + surgical frontmatter
/// rewrite (line-targeted — never re-serializes the whole frontmatter, preserving
/// field order and comments). Builds on `SemVer` (Interview/SemVer.swift).
enum Versioning {

    /// Heuristic: structural change (H2 sections added/removed/retitled) → minor;
    /// content-only edits → patch.
    static func suggestBump(old: String, new: String) -> SemVer.Kind {
        let oldHeadings = Validator.fenceAwareHeadings(of: Frontmatter.split(old).body)
        let newHeadings = Validator.fenceAwareHeadings(of: Frontmatter.split(new).body)
        return oldHeadings == newHeadings ? .patch : .minor
    }

    /// Whether a save should offer a bump: the body changed but `version` didn't.
    static func needsBumpPrompt(old: String, new: String) -> Bool {
        let (oldFields, oldBody) = Frontmatter.split(old)
        let (newFields, newBody) = Frontmatter.split(new)
        guard oldBody != newBody else { return false }
        return (oldFields["version"] ?? "") == (newFields["version"] ?? "")
            && SemVer(oldFields["version"] ?? "") != nil
    }

    /// Apply a bump to document text: rewrite the `version:` and `last_reviewed:`
    /// frontmatter lines in place and append a Change Log entry (creating nothing —
    /// the entry is only added when a `## Change Log` section exists).
    static func applyBump(to text: String, newVersion: SemVer, today: String, summary: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return text }

        if let vIdx = lines[1..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("version:") }) {
            lines[vIdx] = "version: \(newVersion)"
        }
        if let rIdx = lines[1..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("last_reviewed:") }) {
            lines[rIdx] = "last_reviewed: \(today)"
        }
        var out = lines.joined(separator: "\n")

        let entry = "- \(today) · v\(newVersion) — \(summary)"
        if let clRange = out.range(of: "## Change Log") {
            if let lineEnd = out[clRange.upperBound...].firstIndex(of: "\n") {
                out.insert(contentsOf: "\n\n\(entry)", at: lineEnd)
            } else {
                out += "\n\n\(entry)"
            }
        }
        return out
    }
}

extension SemVer {
    enum Kind { case patch, minor }

    func bumped(_ kind: Kind) -> SemVer {
        switch kind {
        case .patch: return bumpedPatch
        case .minor: return bumpedMinor
        }
    }
}

/// Classifies a build's artifacts against the files already deployed at a directory
/// target — powering the "3 changed · 2 new · 1 unchanged" push summary and the
/// skip-unchanged optimization.
struct PushPlan {
    var changed: [BuildArtifact] = []
    var new: [BuildArtifact] = []
    var unchanged: [BuildArtifact] = []

    var summary: String {
        var parts: [String] = []
        if !changed.isEmpty { parts.append("\(changed.count) changed") }
        if !new.isEmpty { parts.append("\(new.count) new") }
        if !unchanged.isEmpty { parts.append("\(unchanged.count) unchanged") }
        return parts.isEmpty ? "nothing to push" : parts.joined(separator: " · ")
    }

    /// Artifacts that actually need writing.
    var toWrite: [BuildArtifact] { changed + new }

    static func plan(_ result: BuildResult, into root: URL) -> PushPlan {
        var plan = PushPlan()
        for artifact in result.artifacts {
            let dest = root.appendingPathComponent(artifact.relativePath)
            if let existing = try? String(contentsOf: dest, encoding: .utf8) {
                if existing == artifact.contents {
                    plan.unchanged.append(artifact)
                } else {
                    plan.changed.append(artifact)
                }
            } else {
                plan.new.append(artifact)
            }
        }
        return plan
    }
}
