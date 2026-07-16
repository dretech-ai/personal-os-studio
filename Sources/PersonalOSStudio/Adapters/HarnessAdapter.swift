import Foundation

/// A pluggable harness adapter: transforms canonical Agent OS files into the artifacts
/// one harness reads, and describes how those artifacts are delivered. Implementations
/// are stateless values; the canonical store is passed into `build(from:)`.
///
/// Adding a harness = one conforming type registered in `AppState.adapters`. The
/// harness row activates automatically; the build/push panel renders from `delivery`.
protocol HarnessAdapter {
    /// Matches `Harness.id` in Models.swift.
    var harnessID: String { get }

    /// Transform the store's included canonical files into harness artifacts.
    func build(from store: CanonicalStore) -> BuildResult

    /// How artifacts reach the harness.
    var delivery: DeliveryKind { get }
}

/// How a harness receives its artifacts.
enum DeliveryKind {
    /// Artifacts are files written into a directory target (OpenClaw workspaces,
    /// Hermes' `~/.hermes`, a Codex repo root…).
    case directory(DirectoryDelivery)
    /// The harness has no file surface — artifacts are paste-ready blocks the user
    /// copies into the tool's UI (Claude Cowork's instruction fields).
    case clipboard(ClipboardDelivery)
}

/// One selectable push destination for a directory-delivered harness.
struct PushTargetOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let url: URL
}

/// Where one artifact lands during a directory push.
enum ArtifactDestination {
    /// Under the user-selected push target.
    case target
    /// Under a fixed directory independent of the selected target
    /// (e.g. Codex personal skills → `~/.codex/skills`).
    case fixed(URL, label: String)
}

/// Lets the user pick a push target themselves (e.g. Codex's git repo root).
struct CustomTargetSpec {
    let buttonLabel: String                 // "Choose git repo…"
    let panelMessage: String                // NSOpenPanel message
    /// Validate a chosen directory; nil = OK, else the error to show.
    let validate: (URL) -> String?
    /// UserDefaults key remembering the last confirmed choice.
    let defaultsKey: String
}

/// Descriptor for directory delivery. OpenClaw keeps its bespoke rich panel (settings,
/// TCC diagnosis, container restart); this descriptor carries what a generic directory
/// panel needs for simpler harnesses (Hermes, Codex).
struct DirectoryDelivery {
    /// Section heading, e.g. "Target workspace" / "Hermes home".
    let targetLabel: String
    /// Discover the currently available push targets (may be a single fixed dir).
    let discoverTargets: () -> [PushTargetOption]
    /// Shown when `discoverTargets` returns nothing (e.g. "Hermes not installed — …").
    let noTargetGuidance: String
    /// Optional action run after a successful push (e.g. tighten permissions).
    /// Returns log lines to append to the push log.
    let postPush: ((_ target: PushTargetOption, _ result: BuildResult) async -> [String])?
    /// Optional liveness probe: label + URL fetched with a short timeout.
    let healthProbe: HealthProbe?
    /// Optional filesystem readiness badge (e.g. "codex binary not found — …").
    let readiness: (() -> (ok: Bool, message: String))?
    /// Optional user-chosen target support (folder picker in the panel).
    let customTarget: CustomTargetSpec?
    /// Optional per-artifact routing; nil = everything under the selected target.
    let partition: ((BuildArtifact) -> ArtifactDestination)?

    init(targetLabel: String,
         discoverTargets: @escaping () -> [PushTargetOption],
         noTargetGuidance: String,
         postPush: ((_ target: PushTargetOption, _ result: BuildResult) async -> [String])? = nil,
         healthProbe: HealthProbe? = nil,
         readiness: (() -> (ok: Bool, message: String))? = nil,
         customTarget: CustomTargetSpec? = nil,
         partition: ((BuildArtifact) -> ArtifactDestination)? = nil) {
        self.targetLabel = targetLabel
        self.discoverTargets = discoverTargets
        self.noTargetGuidance = noTargetGuidance
        self.postPush = postPush
        self.healthProbe = healthProbe
        self.readiness = readiness
        self.customTarget = customTarget
        self.partition = partition
    }
}

/// A simple GET-based liveness probe for a harness's local service.
struct HealthProbe {
    let label: String       // e.g. "Hermes dashboard"
    let url: String         // e.g. "http://127.0.0.1:9119/"
}

/// Descriptor for clipboard delivery: artifacts double as named paste blocks
/// (`BuildArtifact.relativePath` is the block name).
struct ClipboardDelivery {
    /// One-line framing shown above the blocks (e.g. "Pushing means pasting —
    /// Studio cannot write this tool's config.").
    let note: String
    /// Ordered paste instructions per block name.
    let instructions: [String: [String]]
    /// Optional readiness check (pure filesystem reads), rendered as a badge:
    /// e.g. "Cowork detected in Claude Desktop" vs what to verify.
    let readiness: (() -> (ok: Bool, message: String))?

    init(note: String,
         instructions: [String: [String]],
         readiness: (() -> (ok: Bool, message: String))? = nil) {
        self.note = note
        self.instructions = instructions
        self.readiness = readiness
    }
}
