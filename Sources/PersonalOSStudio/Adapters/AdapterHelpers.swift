import Foundation

/// Transform utilities shared by every harness adapter, extracted from the original
/// OpenClaw adapter. These encode the adapter contract from `agent_os/adapters/README.md`:
/// banners preserved, frontmatter → provenance comment, fixed layer orderings, and the
/// canonical → harness section renames that all SOUL.md-style outputs share.
enum AdapterHelpers {

    // MARK: Section tables (shared by OpenClaw / Hermes / Cowork / Codex per their specs)

    /// Identity H2 renames used by every harness's identity output.
    static let identityRenames: [(from: String, to: String)] = [
        ("Agent Identity", "Agent"),
        ("User Profile", "User"),
        ("Operating Principles", "Principles"),
        ("Boundaries", "Boundaries"),
        ("Style & Tone", "Style"),
        ("Output Expectations", "Output"),
        ("Escalation & Confirmation", "Escalation"),
    ]

    /// Authoring-artifact sections dropped from rendered output.
    static let droppedSections: Set<String> = ["change log", "classification"]

    /// Context file order within a combined context render.
    static let contextOrder = ["role", "domain", "team"]

    /// Memory persistent-entry ordering by entry_type.
    static let memoryEntryOrder = ["user", "feedback", "project", "reference"]

    /// Rename an identity heading per the shared table (case-insensitive; pass-through
    /// when unmapped).
    static func renameIdentityHeading(_ heading: String) -> String {
        identityRenames.first { $0.from.compare(heading, options: .caseInsensitive) == .orderedSame }?.to ?? heading
    }

    /// Sort context files role → domain → team, then by filename.
    static func sortedContext(_ files: [CanonicalFile]) -> [CanonicalFile] {
        files.sorted { a, b in
            let ai = contextOrder.firstIndex(of: a.contextType ?? "") ?? 99
            let bi = contextOrder.firstIndex(of: b.contextType ?? "") ?? 99
            if ai != bi { return ai < bi }
            return a.filename < b.filename
        }
    }

    /// Sort skills alphabetically by canonical `name`.
    static func sortedSkills(_ files: [CanonicalFile]) -> [CanonicalFile] {
        files.sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    // MARK: Banner / provenance / text helpers

    /// The file's classification banner, or a synthesized one from its designation.
    static func bannerOrDefault(_ banner: String, designation: Designation) -> String {
        if !banner.isEmpty { return firstBlockquoteLine(banner) }
        return "> **Classification: \(designation.label)**"
    }

    /// Collapse a multi-line blockquote banner to its first line (drops the
    /// FICTIONAL-SAMPLE second paragraph etc.).
    static func firstBlockquoteLine(_ banner: String) -> String {
        for line in banner.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") && t != ">" { return t }
        }
        return banner
    }

    /// Frontmatter provenance as a single HTML comment (survives rendering; auditable).
    static func provenanceComment(_ fields: [String: String]) -> String {
        let owner = fields["owner"] ?? "unknown"
        let version = fields["version"] ?? "0.0.0"
        let reviewed = fields["last_reviewed"] ?? "—"
        let desig = fields["designation"] ?? "Unknown"
        return "<!-- owner: \(owner) | version: \(version) | reviewed: \(reviewed) | designation: \(desig) -->"
    }

    /// First sentence of a block of text (used for skill descriptions from Trigger).
    static func firstSentence(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if let dot = flat.firstIndex(of: ".") {
            return String(flat[...dot]).trimmingCharacters(in: .whitespaces)
        }
        return flat
    }
}
