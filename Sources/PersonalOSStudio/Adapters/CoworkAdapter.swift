import Foundation

/// Implements the Claude Cowork adapter documented in
/// `agent_os/adapters/claude-cowork.md` (pinned Claude Desktop 1.8555.x, Cowork GA).
///
/// Cowork has **no file-based instruction discovery** — its two surfaces are UI fields
/// in Claude Desktop: Global instructions (Settings > Cowork) and per-Space Folder
/// instructions. This adapter therefore produces paste-ready blocks (clipboard
/// delivery); Studio never writes into `~/Library/Application Support/Claude/`.
struct CoworkAdapter: HarnessAdapter {

    let harnessID = "claude-cowork"

    static let globalBlock = "Global instructions"
    static let folderBlock = "Folder instructions"

    /// Conservative length threshold; the real UI-field limit is undocumented.
    static let lengthThreshold = 8_000

    /// Sections dropped under length pressure, in spec order (Change Log is already
    /// dropped globally; these are the post-rename names).
    static let lengthDropOrder = ["Style", "Output", "Escalation"]

    var delivery: DeliveryKind {
        .clipboard(ClipboardDelivery(
            note: "Cowork reads instructions from fields inside Claude Desktop — pushing means pasting. The pasted blocks are PII in Anthropic's app state; never paste connection secrets.",
            instructions: [
                Self.globalBlock: [
                    "In Claude Desktop: Settings > Cowork > Global instructions > Edit.",
                    "Paste this block, replacing existing content. Save.",
                    "Applies to every Cowork session — no restart needed.",
                ],
                Self.folderBlock: [
                    "In Claude Desktop: Cowork tab → add or pick a Cowork Space (the folder the agent operates on).",
                    "Set the Space's Folder instructions to this block. Save.",
                    "Loads whenever that Space is selected.",
                ],
            ],
            readiness: { Self.detectEnablement() }))
    }

    /// Read-only enablement check: Claude Desktop present + the Cowork marker file.
    static func detectEnablement() -> (ok: Bool, message: String) {
        let fm = FileManager.default
        let app = fm.fileExists(atPath: "/Applications/Claude.app")
        let marker = fm.fileExists(atPath: (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Claude/cowork-enabled-cli-ops.json"))
        if app && marker { return (true, "Cowork detected in Claude Desktop") }
        if app { return (false, "Claude Desktop found, but no Cowork marker — check the Cowork tab and your plan") }
        return (false, "Claude Desktop not found at /Applications/Claude.app")
    }

    // MARK: Build

    func build(from store: CanonicalStore) -> BuildResult {
        var result = BuildResult()

        buildGlobalBlock(from: store, into: &result)
        buildFolderBlock(from: store, into: &result)

        if result.artifacts.isEmpty {
            result.warnings.append("Nothing selected to build. Check at least one Identity or Context file in the browser.")
        }
        return result
    }

    // MARK: Identity (+ user/feedback memory + personal skills) → Global instructions

    private func buildGlobalBlock(from store: CanonicalStore, into result: inout BuildResult) {
        let identities = store.includedFiles(.identity)
        guard let file = identities.first else {
            result.warnings.append("No Identity file selected — the Global instructions block was not generated.")
            return
        }
        if identities.count > 1 {
            result.warnings.append("Multiple Identity files selected; only \(file.filename) was used for Global instructions.")
        }

        let raw = store.read(file)
        let (fields, body) = Frontmatter.split(raw)
        let parsed = MarkdownSections.parse(body)

        var out = ""
        out += AdapterHelpers.bannerOrDefault(parsed.banner, designation: file.designation) + "\n"
        out += AdapterHelpers.provenanceComment(fields) + "\n\n"
        for (heading, sectionBody) in parsed.sections {
            if AdapterHelpers.droppedSections.contains(heading.lowercased()) { continue }
            out += "## \(AdapterHelpers.renameIdentityHeading(heading))\n\n\(sectionBody)\n\n"
        }

        var strongest = file.designation

        // Checked user/feedback persistent entries inline as Persistent facts
        // (they apply across every Cowork session).
        let globalEntries = memoryEntries(in: store, types: ["user", "feedback"])
        if !globalEntries.isEmpty {
            out += "## Persistent facts\n\n"
            for entry in globalEntries {
                out += entryInline(entry.file, body: entry.body) + "\n\n"
                if entry.file.designation.strength > strongest.strength { strongest = entry.file.designation }
            }
        }

        // Checked personal-scope skills inline their procedure (the include checkbox
        // is the opt-in; the spec warns against pasting skills wholesale).
        appendSkills(from: store, scope: "personal", header: "## Skills", to: &out, strongest: &strongest)

        var (contents, dropped) = Self.applyLengthPressure(out)
        contents = contents.trimmingCharacters(in: .newlines) + "\n"
        if !dropped.isEmpty {
            result.warnings.append("Global instructions exceeded ~\(Self.lengthThreshold) chars — dropped section(s) per the spec's order: \(dropped.joined(separator: ", ")).")
        }

        result.artifacts.append(BuildArtifact(
            relativePath: Self.globalBlock,
            contents: contents,
            sourceDescription: "Identity ← \(file.filename)"
                + (globalEntries.isEmpty ? "" : " + \(globalEntries.count) memory entr\(globalEntries.count == 1 ? "y" : "ies")"),
            designation: strongest))
    }

    // MARK: Context (+ agent job + project memory/skills) → Folder instructions

    private func buildFolderBlock(from store: CanonicalStore, into result: inout BuildResult) {
        let ctx = store.includedFiles(.context)
        let agents = store.includedFiles(.agents).filter { !$0.isTemplate }
        guard !ctx.isEmpty || !agents.isEmpty else {
            result.warnings.append("No Context or Agent file selected — the Folder instructions block was not generated.")
            return
        }

        var out = ""
        out += "<!-- Generated by Personal OS Studio · Claude Cowork adapter -->\n\n"
        var strongest = Designation.pub

        for file in AdapterHelpers.sortedContext(ctx) {
            let raw = store.read(file)
            let (_, body) = Frontmatter.split(raw)
            let parsed = MarkdownSections.parse(body)
            if file.designation.strength > strongest.strength { strongest = file.designation }

            let type = (file.contextType ?? "context").capitalized
            out += "# \(type) context\n\n"
            if !parsed.banner.isEmpty {
                out += AdapterHelpers.firstBlockquoteLine(parsed.banner) + "\n\n"
            }
            for (heading, sectionBody) in parsed.sections {
                if AdapterHelpers.droppedSections.contains(heading.lowercased()) { continue }
                out += "### \(heading)\n\n\(sectionBody)\n\n"
            }
        }

        // Active agent job description(s) from the agents layer.
        for agent in agents {
            let raw = store.read(agent)
            let (_, body) = Frontmatter.split(raw)
            let parsed = MarkdownSections.parse(body)
            if agent.designation.strength > strongest.strength { strongest = agent.designation }
            let name = agent.name ?? agent.title
            out += "# Active agent: \(name)\n\n"
            if !parsed.banner.isEmpty { out += AdapterHelpers.firstBlockquoteLine(parsed.banner) + "\n\n" }
            for (heading, sectionBody) in parsed.sections {
                if AdapterHelpers.droppedSections.contains(heading.lowercased()) { continue }
                out += "### \(heading)\n\n\(sectionBody)\n\n"
            }
        }

        // Checked project persistent entries belong to the Space, not Global.
        let projectEntries = memoryEntries(in: store, types: ["project", "reference"])
        if !projectEntries.isEmpty {
            out += "# Project memory\n\n"
            for entry in projectEntries {
                out += entryInline(entry.file, body: entry.body) + "\n\n"
                if entry.file.designation.strength > strongest.strength { strongest = entry.file.designation }
            }
        }

        appendSkills(from: store, scope: "project", header: "# Skills", to: &out, strongest: &strongest)

        result.artifacts.append(BuildArtifact(
            relativePath: Self.folderBlock,
            contents: out.trimmingCharacters(in: .newlines) + "\n",
            sourceDescription: "Context ← \(AdapterHelpers.sortedContext(ctx).map(\.filename).joined(separator: ", "))"
                + (agents.isEmpty ? "" : " + \(agents.map(\.filename).joined(separator: ", "))"),
            designation: strongest))
    }

    // MARK: Helpers

    private func memoryEntries(in store: CanonicalStore, types: [String]) -> [(file: CanonicalFile, body: String)] {
        store.includedFiles(.memory)
            .filter { $0.entryType.map(types.contains) == true && $0.name != nil }
            .map { file in
                let (_, body) = Frontmatter.split(store.read(file))
                let parsed = MarkdownSections.parse(body)
                return (file, parsed.section("Entry") ?? body)
            }
    }

    private func entryInline(_ file: CanonicalFile, body: String) -> String {
        "**\(file.name ?? file.filename)** (\(file.entryType ?? "entry")): "
            + body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendSkills(from store: CanonicalStore, scope: String, header: String,
                              to out: inout String, strongest: inout Designation) {
        let skills = AdapterHelpers.sortedSkills(
            store.includedFiles(.skills).filter { !$0.isTemplate && $0.name != nil && $0.scope == scope })
        guard !skills.isEmpty else { return }
        out += "\(header)\n\n"
        for file in skills {
            guard let name = file.name else { continue }
            let raw = store.read(file)
            let (_, body) = Frontmatter.split(raw)
            let parsed = MarkdownSections.parse(body)
            if file.designation.strength > strongest.strength { strongest = file.designation }

            let trigger = AdapterHelpers.firstSentence(parsed.section("Trigger") ?? "")
            out += "### Skill: \(name)\n\n"
            if !trigger.isEmpty { out += "When to use: \(trigger)\n\n" }
            for keep in ["Inputs", "Procedure", "Output"] {
                if let s = parsed.section(keep) {
                    out += "**\(keep):**\n\n\(s)\n\n"
                }
            }
        }
    }

    /// Under length pressure, drop sections in the spec's order (never Classification,
    /// Agent, Principles, or Boundaries). Returns the trimmed text + dropped names.
    static func applyLengthPressure(_ text: String) -> (String, dropped: [String]) {
        var current = text
        var dropped: [String] = []
        for section in lengthDropOrder where current.count > lengthThreshold {
            if let trimmed = removeSection(named: section, from: current) {
                current = trimmed
                dropped.append(section)
            }
        }
        return (current, dropped)
    }

    /// Remove one `## <name>` section (heading through the next `## ` or end).
    private static func removeSection(named name: String, from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "## \(name)"
        }) else { return nil }
        var end = lines.count
        for i in (start + 1)..<lines.count where lines[i].hasPrefix("## ") {
            end = i
            break
        }
        var kept = lines
        kept.removeSubrange(start..<end)
        return kept.joined(separator: "\n")
    }
}
