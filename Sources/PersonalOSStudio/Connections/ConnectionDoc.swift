import Foundation

/// A parsed canonical Connections-layer document (see connection.template.md):
/// mechanism, access mode, capabilities, and the Configuration block — including the
/// proposed `mcpServers` entry extracted from its fenced JSON, when present.
struct ConnectionDoc: Identifiable {
    let id: String
    let file: CanonicalFile
    let name: String
    let mechanism: String          // mcp | cli | api | builtin (free text tolerated)
    let accessMode: String
    let capabilities: [String]
    let configurationBlock: String
    let securityNotes: String
    var warnings: [String] = []

    /// The `mcpServers.<name>` subtree from the Configuration section's JSON, if any.
    let proposedEntry: [String: Any]?

    var isMCP: Bool { mechanism.lowercased() == "mcp" }
    var isReadOnly: Bool { accessMode.lowercased().contains("read-only") }

    static func parse(_ file: CanonicalFile, store: CanonicalStore) -> ConnectionDoc {
        let raw = store.read(file)
        let (fields, body) = Frontmatter.split(raw)
        let parsed = MarkdownSections.parse(body)
        var warnings: [String] = []

        let name = fields["name"] ?? file.filename.replacingOccurrences(of: ".md", with: "")
        let mechanism = fields["mechanism"] ?? {
            warnings.append("no mechanism field — treating as manual-only")
            return "unknown"
        }()
        let accessMode = fields["access_mode"] ?? parsed.section("Access Mode")?
            .components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""

        let capabilities = (parsed.section("Capabilities") ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("-") }
            .map { String($0.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if capabilities.isEmpty { warnings.append("no Capabilities listed") }

        let configuration = parsed.section("Configuration") ?? ""
        if configuration.isEmpty { warnings.append("no Configuration section") }

        var entry: [String: Any]?
        if let json = Self.firstFencedJSON(in: configuration),
           let servers = json["mcpServers"] as? [String: Any] {
            entry = servers[name] as? [String: Any]
            if entry == nil, let only = servers.values.first as? [String: Any], servers.count == 1 {
                entry = only
                warnings.append("mcpServers key doesn't match the canonical name \"\(name)\"")
            }
        }

        return ConnectionDoc(
            id: file.id, file: file, name: name, mechanism: mechanism,
            accessMode: accessMode, capabilities: capabilities,
            configurationBlock: configuration,
            securityNotes: parsed.section("Security Notes") ?? "",
            warnings: warnings,
            proposedEntry: entry)
    }

    /// First ```json fenced block in a section, parsed.
    static func firstFencedJSON(in text: String) -> [String: Any]? {
        var inFence = false
        var buffer: [String] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inFence { break }        // closing fence — stop at the first block
                inFence = t.lowercased().contains("json") || t == "```"
                continue
            }
            if inFence { buffer.append(line) }
        }
        guard !buffer.isEmpty,
              let data = buffer.joined(separator: "\n").data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Scan the proposed entry's string values for literal secrets. Env-var references
    /// (`$VAR`, `${VAR}`) pass; token-shaped literals are refused.
    func literalSecretFinding() -> String? {
        guard let entry = proposedEntry else { return nil }
        return Self.scanForSecrets(entry)
    }

    private static let secretPatterns: [String] = [
        #"^sk-[A-Za-z0-9_-]{8,}"#,          // OpenAI/Anthropic-style keys
        #"^gh[pousr]_[A-Za-z0-9]{16,}"#,    // GitHub tokens
        #"^xox[a-z]-"#,                     // Slack tokens
        #"(?i)^bearer\s+\S{10,}"#,          // bearer literals
        #"^[A-Fa-f0-9]{32,}$"#,             // long hex
    ]

    static func scanForSecrets(_ object: Any) -> String? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if let hit = scanForSecrets(value) { return "\(key): \(hit)" }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let hit = scanForSecrets(value) { return hit }
            }
        } else if let string = object as? String {
            let t = string.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("$") else { return nil }   // env-var reference — fine
            for pattern in secretPatterns where t.range(of: pattern, options: .regularExpression) != nil {
                return "looks like a literal secret (\(String(t.prefix(8)))…)"
            }
        }
        return nil
    }
}
