import Foundation

/// One canonical file the interview can build. Derived from a `*.template.md` in the
/// canonical repo: it carries the template's frontmatter and its ordered H2 headings so
/// the interviewer knows exactly what content the file needs.
struct InterviewTarget: Identifiable, Hashable {
    let id: String            // template file path
    let layer: Layer
    let title: String         // e.g. "Identity" or "Context · role"
    let templateURL: URL
    let frontmatter: [String: String]
    let sectionHeadings: [String]
    /// Suggested path relative to the canonical repo root, e.g. "identity/identity.md".
    let suggestedRelativePath: String

    static func == (a: InterviewTarget, b: InterviewTarget) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Template filenames the interview can build. Scaffolds like backlog and the
    /// working-memory notebook are intentionally excluded.
    static let trainable: Set<String> = [
        "identity.template.md",
        "role.template.md", "domain.template.md", "team.template.md",
        "skill.template.md",
        "MEMORY.template.md", "persistent.entry.template.md",
        "connection.template.md", "agent.template.md",
    ]

    /// Human-friendly titles per template basename (falls back to "Layer · base").
    private static let titles: [String: String] = [
        "identity": "My Identity",
        "role": "Role context",
        "domain": "Domain context",
        "team": "Team context",
        "skill": "A Skill",
        "MEMORY": "Memory index",
        "persistent.entry": "A Memory entry",
        "connection": "A Connection",
        "agent": "An Agent definition",
    ]

    /// Instance templates of multi layers — each interview run should create a NEW
    /// uniquely-named file (skills/my-skill.md), never overwrite the template-base
    /// path. Fixed-path documents (identity, context types, the MEMORY index) are not
    /// instances even when their layer is multi.
    private static let instanceBases: Set<String> = [
        "skill", "persistent.entry", "connection", "agent",
    ]

    /// True when this target creates one instance among many (name-derived filename).
    var isInstance: Bool {
        let base = (templateURL.lastPathComponent as NSString)
            .replacingOccurrences(of: ".template.md", with: "")
        return layer.cardinality == .multi && Self.instanceBases.contains(base)
    }

    /// Build a target from a template file, reading its frontmatter + section headings.
    /// Returns nil for templates that aren't trainable documents.
    static func from(template file: CanonicalFile, store: CanonicalStore) -> InterviewTarget? {
        guard file.isTemplate, trainable.contains(file.filename) else { return nil }
        let text = store.read(file)
        let (fields, body) = Frontmatter.split(text)
        let sections = MarkdownSections.parse(body)
        // Skip the boilerplate "Classification" section — it's explained, not authored.
        let headings = sections.sections
            .map(\.heading)
            .filter { $0.compare("Classification", options: .caseInsensitive) != .orderedSame }
        guard !headings.isEmpty else { return nil }

        let base = file.filename
            .replacingOccurrences(of: ".template.md", with: "")
            .replacingOccurrences(of: ".template", with: "")
        let cleanBase = base.hasSuffix(".md") ? base : base + ".md"

        let title = titles[base] ?? "\(file.layer.title) · \(base)"

        return InterviewTarget(
            id: file.id,
            layer: file.layer,
            title: title,
            templateURL: file.url,
            frontmatter: fields,
            sectionHeadings: headings,
            suggestedRelativePath: "\(file.layer.rawValue)/\(cleanBase)"
        )
    }

    /// All buildable targets across every layer, sorted by canonical load order then title.
    static func all(in store: CanonicalStore) -> [InterviewTarget] {
        var targets: [InterviewTarget] = []
        for layer in Layer.allCases {
            for file in store.files(layer) where file.isTemplate {
                if let t = from(template: file, store: store) { targets.append(t) }
            }
        }
        let order = Layer.allCases.map(\.rawValue)
        return targets.sorted { a, b in
            let ia = order.firstIndex(of: a.layer.rawValue) ?? 0
            let ib = order.firstIndex(of: b.layer.rawValue) ?? 0
            if ia != ib { return ia < ib }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}
