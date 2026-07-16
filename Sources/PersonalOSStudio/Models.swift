import Foundation

// MARK: - Designation

enum Designation: String {
    case pii = "PII"
    case enterprise = "Enterprise"
    case pub = "Public"
    case unknown = "Unknown"

    var label: String { self == .pub ? "Public" : rawValue }

    /// Ordered strongest → weakest for "strongest classification governs".
    var strength: Int {
        switch self {
        case .pii: return 3
        case .enterprise: return 2
        case .pub: return 1
        case .unknown: return 0
        }
    }
}

// MARK: - Canonical layers

enum Layer: String, CaseIterable, Identifiable {
    case identity, context, skills, memory, connections, agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .identity: return "Identity"
        case .context: return "Context"
        case .skills: return "Skills"
        case .memory: return "Memory"
        case .connections: return "Connections"
        case .agents: return "Agents"
        }
    }

    var symbol: String {
        switch self {
        case .identity: return "person.crop.circle"
        case .context: return "square.stack.3d.up"
        case .skills: return "wand.and.stars"
        case .memory: return "brain"
        case .connections: return "point.3.connected.trianglepath.dotted"
        case .agents: return "cpu"
        }
    }

    var blurb: String {
        switch self {
        case .identity: return "Who the agent is, how it works, durable rules."
        case .context: return "Role, domain, and team — the work environment."
        case .skills: return "Named, invokable procedures."
        case .memory: return "Working notebook + persistent typed entries."
        case .connections: return "Integrations the agent can reach."
        case .agents: return "Jobs that run on top of the OS."
        }
    }

    /// How many documents a layer is meant to hold (product decision, 2026-07-06).
    /// Views and the validator switch on this — never on layer identity directly.
    enum Cardinality {
        case single         // exactly one document (identity)
        case singlePerType  // one per context_type (role / domain / team)
        case multi          // any number of instance documents
    }

    var cardinality: Cardinality {
        switch self {
        case .identity: return .single
        case .context: return .singlePerType
        case .skills, .memory, .connections, .agents: return .multi
        }
    }

    /// What one instance of a multi layer is called (drives "+ New …" labels).
    var instanceNoun: String {
        switch self {
        case .identity: return "identity"
        case .context: return "context"
        case .skills: return "skill"
        case .memory: return "memory entry"
        case .connections: return "connection"
        case .agents: return "agent"
        }
    }
}

// MARK: - Canonical file

final class CanonicalFile: Identifiable, ObservableObject {
    let id: String
    let url: URL
    let layer: Layer
    let frontmatter: [String: String]

    /// A template scaffold (…template.md) — not real content.
    let isTemplate: Bool
    /// A fictional worked example (sample.*, sample: true).
    let isExample: Bool

    @Published var include: Bool

    init(url: URL, layer: Layer, frontmatter: [String: String], isTemplate: Bool, isExample: Bool) {
        self.id = url.path
        self.url = url
        self.layer = layer
        self.frontmatter = frontmatter
        self.isTemplate = isTemplate
        self.isExample = isExample
        // Default include: real, active files. Templates never; examples off by default.
        self.include = !isTemplate && !isExample
    }

    var filename: String { url.lastPathComponent }

    var title: String {
        frontmatter["title"] ?? filename
    }

    var designation: Designation {
        Designation(rawValue: frontmatter["designation"] ?? "") ?? .unknown
    }

    var status: String { frontmatter["status"] ?? "—" }
    var version: String { frontmatter["version"] ?? "—" }
    var contextType: String? { frontmatter["context_type"] }
    var scope: String? { frontmatter["scope"] }
    var entryType: String? { frontmatter["entry_type"] }
    var name: String? { frontmatter["name"] }

    var kindBadge: String {
        if isTemplate { return "Template" }
        if isExample { return "Example" }
        return "Content"
    }
}

// MARK: - Harnesses

enum HarnessStatus {
    case active
    case comingSoon
}

struct Harness: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let status: HarnessStatus

    static let all: [Harness] = [
        Harness(id: "openclaw",
                name: "OpenClaw",
                subtitle: "Self-hosted gateway · personal_ai",
                symbol: "pawprint.fill",
                status: .active),
        Harness(id: "hermes",
                name: "Hermes",
                subtitle: "Markdown workspace agent",
                symbol: "bolt.horizontal.circle",
                status: .comingSoon),
        Harness(id: "claude-cowork",
                name: "Claude Cowork",
                subtitle: "Agentic mode in Claude Desktop",
                symbol: "person.2.wave.2",
                status: .comingSoon),
        Harness(id: "codex",
                name: "OpenAI Codex",
                subtitle: "Codex CLI · AGENTS.md",
                symbol: "chevron.left.forwardslash.chevron.right",
                status: .comingSoon),
    ]
}

// MARK: - OpenClaw workspace

struct OpenClawWorkspace: Identifiable, Hashable {
    let id: String        // directory name, e.g. "workspace-chief-of-staff"
    let url: URL

    var displayName: String {
        if id == "workspace" { return "workspace (default)" }
        return id.replacingOccurrences(of: "workspace-", with: "")
    }
}

// MARK: - Build artifacts

/// One file the adapter produced, held in memory until pushed.
struct BuildArtifact: Identifiable {
    let id = UUID()
    /// Path relative to the workspace root, e.g. "SOUL.md" or "skills/foo/SKILL.md".
    let relativePath: String
    let contents: String
    let sourceDescription: String
    let designation: Designation

    var byteCount: Int { contents.utf8.count }
}

struct BuildResult {
    var artifacts: [BuildArtifact] = []
    var warnings: [String] = []
    /// Strongest designation across all artifacts.
    var effectiveDesignation: Designation {
        artifacts.map(\.designation).max(by: { $0.strength < $1.strength }) ?? .unknown
    }
}
