import Foundation
import Combine

extension NSError {
    /// POSIX errno from the underlying error chain, or -1. Used to spot TCC
    /// permission denials (EPERM/EACCES) on removable volumes.
    var underlyingPosixCode: Int32 {
        if domain == NSPOSIXErrorDomain { return Int32(code) }
        if let underlying = userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.underlyingPosixCode
        }
        return -1
    }
}

enum GatewayHealth: Equatable {
    case unconfigured
    case unknown
    case checking
    case healthy(String)
    case down(String)

    var isHealthy: Bool { if case .healthy = self { return true }; return false }
}

/// Talks to a user-configured OpenClaw instance: discovers workspaces under the
/// configured state dir, checks the gateway health endpoint, writes generated
/// artifacts into a chosen workspace, and restarts the container. Nothing here is
/// assumed — all locations/names come from `OpenClawSettings` via `apply(_:)`
/// (except headless self-tests, which use `init(stateDir:)` directly).
final class OpenClawService: ObservableObject {
    /// Host path that is mounted to /home/node/.openclaw inside the container.
    /// nil until the user configures OpenClaw.
    @Published var stateDir: URL?
    @Published var workspaces: [OpenClawWorkspace] = []
    @Published var health: GatewayHealth = .unconfigured
    @Published var lastPushLog: [String] = []

    @Published var gatewayURL: String = ""
    @Published var containerName: String = ""
    @Published var controlUI: String = ""

    private let fm = FileManager.default

    /// App path: starts unconfigured; call `apply(_:)` with settings.
    init() {}

    /// Direct path for headless self-tests (bypasses settings).
    init(stateDir: URL) {
        self.stateDir = stateDir
        self.gatewayURL = OpenClawSettings.defaultGatewayBaseURL + "/healthz"
        self.controlUI = OpenClawSettings.defaultGatewayBaseURL + "/"
        self.health = .unknown
        discoverWorkspaces()
    }

    /// Re-point the service at the user's confirmed configuration.
    @MainActor
    func apply(_ settings: OpenClawSettings) {
        stateDir = settings.stateDirURL
        gatewayURL = settings.healthURL
        controlUI = settings.controlUIURL
        containerName = settings.containerName
        health = settings.isConfigured ? .unknown : .unconfigured
        discoverWorkspaces()
    }

    var isConfigured: Bool { stateDir != nil }
    var stateDirExists: Bool {
        guard let dir = stateDir else { return false }
        return fm.fileExists(atPath: dir.path)
    }

    /// True when the last workspace discovery was blocked by macOS (TCC removable-volume
    /// denial) rather than the directory being empty — the UI should say so.
    @Published var discoveryBlocked = false

    func discoverWorkspaces() {
        guard let stateDir else { workspaces = []; discoveryBlocked = false; return }
        var found: [OpenClawWorkspace] = []
        discoveryBlocked = false
        let listing: [URL]?
        do {
            listing = try fm.contentsOfDirectory(at: stateDir,
                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])
        } catch {
            let ns = error as NSError
            discoveryBlocked = ns.code == NSFileReadNoPermissionError
                || ns.underlyingPosixCode == EPERM || ns.underlyingPosixCode == EACCES
            listing = nil
        }
        if let entries = listing {
            for url in entries {
                let name = url.lastPathComponent
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                guard isDir.boolValue else { continue }
                if name == "workspace" || name.hasPrefix("workspace-") {
                    found.append(OpenClawWorkspace(id: name, url: url))
                }
            }
        }
        found.sort { $0.id < $1.id }
        workspaces = found
    }

    // MARK: Health

    @MainActor
    func checkHealth() async {
        guard isConfigured, !gatewayURL.isEmpty else {
            health = .unconfigured
            return
        }
        health = .checking
        let result = await Self.run("/usr/bin/curl", ["-s", "-m", "4", gatewayURL])
        if result.exitCode == 0, result.stdout.contains("\"ok\":true") {
            health = .healthy(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if result.exitCode == 0, !result.stdout.isEmpty {
            health = .healthy(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            health = .down("Gateway not responding at \(gatewayURL)")
        }
    }

    // MARK: Push

    /// Write build artifacts into the target workspace. Returns a log.
    /// Existing files are backed up to `<name>.bak-studio` once before overwrite.
    /// Writing is delegated to the shared `DirectoryPusher` (adapter framework).
    @discardableResult
    func push(_ result: BuildResult, to workspace: OpenClawWorkspace, backup: Bool) -> [String] {
        let log = DirectoryPusher.push(result, into: workspace.url, backup: backup)
        lastPushLog = log
        return log
    }

    // MARK: Restart

    @MainActor
    func restartContainer() async -> String {
        guard !containerName.isEmpty else {
            return "No container configured — set the container name in OpenClaw settings."
        }
        let result = await Self.run("/usr/bin/env", ["docker", "restart", containerName])
        if result.exitCode == 0 {
            return "Restarted \(containerName): \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return "Restart failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.stdout : result.stderr)"
    }

    // MARK: Process runner

    struct ProcResult { let exitCode: Int32; let stdout: String; let stderr: String }

    static func run(_ launchPath: String, _ args: [String]) async -> ProcResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: launchPath)
                proc.arguments = args
                let outPipe = Pipe(); let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(returning: ProcResult(exitCode: proc.terminationStatus, stdout: out, stderr: err))
                } catch {
                    cont.resume(returning: ProcResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                }
            }
        }
    }
}
