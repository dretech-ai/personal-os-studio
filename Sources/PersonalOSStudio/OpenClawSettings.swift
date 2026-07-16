import Foundation
import Combine

/// User-confirmed OpenClaw configuration. Studio never assumes OpenClaw is installed:
/// everything here starts unset, detection only *suggests*, and nothing is wired until
/// the user confirms it in `OpenClawSettingsView`. Persisted in UserDefaults
/// (mirrors the `LLMSettings` pattern).
@MainActor
final class OpenClawSettings: ObservableObject {
    /// Host path of the OpenClaw state dir (holds workspace*/ and openclaw.json).
    /// nil = the user has not configured OpenClaw.
    @Published var stateDirPath: String? {
        didSet { defaults.set(stateDirPath, forKey: Keys.stateDir) }
    }

    /// Base URL of the gateway (no trailing path). /healthz and the Control UI derive from it.
    @Published var gatewayBaseURL: String {
        didSet { defaults.set(gatewayBaseURL, forKey: Keys.gateway) }
    }

    /// Docker container name for the restart action. Empty = restart unavailable.
    @Published var containerName: String {
        didSet { defaults.set(containerName, forKey: Keys.container) }
    }

    /// Whether the one-time "configure OpenClaw" nudge has been shown.
    @Published var configPrompted: Bool {
        didSet { defaults.set(configPrompted, forKey: Keys.prompted) }
    }

    nonisolated static let defaultGatewayBaseURL = "http://127.0.0.1:18789"

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let stateDir = "openclaw.stateDir"
        static let gateway = "openclaw.gatewayBaseURL"
        static let container = "openclaw.containerName"
        static let prompted = "openclaw.configPrompted"
    }

    init() {
        self.stateDirPath = defaults.string(forKey: Keys.stateDir)
        self.gatewayBaseURL = defaults.string(forKey: Keys.gateway) ?? Self.defaultGatewayBaseURL
        self.containerName = defaults.string(forKey: Keys.container) ?? ""
        self.configPrompted = defaults.bool(forKey: Keys.prompted)
    }

    /// Configured = the user confirmed a state dir and it still exists.
    var isConfigured: Bool {
        guard let path = stateDirPath, !path.isEmpty else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    var stateDirURL: URL? {
        guard let path = stateDirPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Health endpoint derived from the base URL.
    var healthURL: String { gatewayBaseURL.trimmingSlash + "/healthz" }
    /// Control UI derived from the base URL.
    var controlUIURL: String { gatewayBaseURL.trimmingSlash + "/" }

    // MARK: Detection (suggestions only — never persisted automatically)

    /// Directories that look like an OpenClaw state dir: they exist and contain either
    /// a workspace*/ subdir or openclaw.json. Common locations plus any mounted volume —
    /// runs filesystem probes that may touch slow external volumes, so call off the main
    /// thread. Suggestions only; nothing is persisted without the user confirming.
    nonisolated static func detectStateDirs() -> [String] {
        let fm = FileManager.default
        var candidates = [
            (NSHomeDirectory() as NSString).appendingPathComponent(".openclaw"),
            (NSHomeDirectory() as NSString).appendingPathComponent("openclaw"),
        ]
        // External drives are a common home for OpenClaw state — probe mounted volumes.
        for vol in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            candidates.append("/Volumes/\(vol)/openclaw")
        }
        return candidates.filter { path in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
            if fm.fileExists(atPath: (path as NSString).appendingPathComponent("openclaw.json")) { return true }
            let entries = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            return entries.contains { $0 == "workspace" || $0.hasPrefix("workspace-") }
        }
    }

    /// Docker containers whose name mentions openclaw. Empty when docker is unavailable.
    static func detectContainers() async -> [String] {
        let result = await OpenClawService.run("/usr/bin/env", ["docker", "ps", "-a", "--format", "{{.Names}}"])
        guard result.exitCode == 0 else { return [] }
        return result.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.localizedCaseInsensitiveContains("openclaw") }
    }
}

private extension String {
    var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
