import Foundation

/// Reads (and — only under strict conditions — edits) OpenClaw's `openclaw.json`.
///
/// Empirical note (pinned against the gateway on this machine, config keys
/// `models/agents/tools/bindings/commands/channels/gateway/meta`): current gateway
/// versions have **no recognized MCP-server section**, and the adapter spec says the
/// path "depends on installed gateway version". Studio therefore only offers a
/// guided WRITE when a recognized container exists (top-level `mcpServers`, or
/// `tools.mcp`); otherwise registration degrades to guided-manual (copy the proposed
/// entry + confirm the path with `openclaw config get`). Writes are always previewed,
/// backed up (.bak-studio), re-parse-verified, and auto-restored on failure.
/// Key order is not preserved on write (JSONSerialization) — the gateway reads JSON
/// semantically; the backup preserves the original bytes.
struct OpenClawConfig {

    enum LoadState {
        case missing(String)          // no config at the expected path
        case unparseable(String)      // exists but isn't valid JSON
        case loaded([String: Any], raw: String)
    }

    enum RegistrationSurface {
        case topLevelMCPServers       // config["mcpServers"] is a dict
        case toolsMCP                 // config["tools"]["mcp"] is a dict
        case none                     // no recognized container → manual-only
    }

    enum Proposal {
        case alreadyRegistered
        case refusedSecret(String)
        case manualOnly(snippet: String, guidance: String)
        case writable(newConfigText: String, snippet: String)
    }

    let url: URL
    let state: LoadState

    static func load(stateDir: URL) -> OpenClawConfig {
        let url = stateDir.appendingPathComponent("openclaw.json")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return OpenClawConfig(url: url, state: .missing("openclaw.json not found at \(url.path)"))
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OpenClawConfig(url: url, state: .unparseable("openclaw.json exists but is not valid JSON"))
        }
        return OpenClawConfig(url: url, state: .loaded(obj, raw: raw))
    }

    var config: [String: Any]? {
        if case .loaded(let obj, _) = state { return obj }
        return nil
    }

    var surface: RegistrationSurface {
        guard let config else { return .none }
        if config["mcpServers"] is [String: Any] { return .topLevelMCPServers }
        if let tools = config["tools"] as? [String: Any], tools["mcp"] is [String: Any] { return .toolsMCP }
        return .none
    }

    /// Server names currently registered in the recognized container.
    var registeredNames: Set<String> {
        guard let config else { return [] }
        switch surface {
        case .topLevelMCPServers:
            return Set((config["mcpServers"] as? [String: Any])?.keys.map { $0 } ?? [])
        case .toolsMCP:
            let tools = config["tools"] as? [String: Any]
            return Set((tools?["mcp"] as? [String: Any])?.keys.map { $0 } ?? [])
        case .none:
            return []
        }
    }

    /// Build the registration proposal for an mcp connection doc.
    func propose(_ doc: ConnectionDoc) -> Proposal {
        guard let entry = doc.proposedEntry else {
            return .manualOnly(
                snippet: doc.configurationBlock,
                guidance: "No mcpServers entry found in the doc's Configuration JSON — register manually per the Configuration section.")
        }
        if let secret = doc.literalSecretFinding() {
            return .refusedSecret("Refusing to write a literal secret into openclaw.json (\(secret)). Use an env-var reference (e.g. \"$TOKEN\") per the connection's Security Notes.")
        }
        if registeredNames.contains(doc.name) {
            return .alreadyRegistered
        }

        let snippet = prettyJSON(["mcpServers": [doc.name: entry]])

        guard var config, case .loaded = state, surface != .none else {
            return .manualOnly(
                snippet: snippet,
                guidance: "This gateway's openclaw.json has no recognized MCP section (keys: \(config.map { $0.keys.sorted().joined(separator: ", ") } ?? "—")). Confirm the correct path with `openclaw config get`, then merge the entry manually. Studio won't guess a write location in a live config.")
        }

        var annotated = entry
        if doc.isReadOnly && annotated["note"] == nil {
            // The schema's Access Mode is source of truth; surface it in the entry.
            annotated["note"] = "read-only connection — enforce via server flags per the canonical doc"
        }

        switch surface {
        case .topLevelMCPServers:
            var servers = config["mcpServers"] as? [String: Any] ?? [:]
            servers[doc.name] = annotated
            config["mcpServers"] = servers
        case .toolsMCP:
            var tools = config["tools"] as? [String: Any] ?? [:]
            var mcp = tools["mcp"] as? [String: Any] ?? [:]
            mcp[doc.name] = annotated
            tools["mcp"] = mcp
            config["tools"] = tools
        case .none:
            break
        }
        return .writable(newConfigText: prettyJSON(config), snippet: snippet)
    }

    /// Back up, write, verify re-parse; restore the backup on any failure.
    func write(newConfigText: String) -> [String] {
        var log: [String] = []
        let fm = FileManager.default
        let backup = url.appendingPathExtension("bak-studio")

        do {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
            log.append("✓ backed up openclaw.json → \(backup.lastPathComponent)")

            try newConfigText.write(to: url, atomically: true, encoding: .utf8)

            // Verify the write round-trips.
            let verify = OpenClawConfig.load(stateDir: url.deletingLastPathComponent())
            guard case .loaded = verify.state else {
                throw NSError(domain: "OpenClawConfig", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "written config failed to re-parse"])
            }
            log.append("✓ wrote openclaw.json (re-parse verified)")
        } catch {
            // Restore and report.
            if fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: url)
                try? fm.copyItem(at: backup, to: url)
                log.append("✗ write failed (\(error.localizedDescription)) — backup restored")
            } else {
                log.append("✗ write failed (\(error.localizedDescription))")
            }
        }
        return log
    }

    private func prettyJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
