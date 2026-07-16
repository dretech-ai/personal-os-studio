import Foundation

/// Implements the Hermes adapter documented in `agent_os/adapters/hermes.md`
/// (pinned Hermes Agent 2026.5.x, Nous Research). Hermes reads instruction files
/// directly from `~/.hermes/` (no workspace subdir): SOUL.md, AGENTS.md, MEMORY.md,
/// skills/<name>/SKILL.md, and persistent memory at memories/<name>.md.
struct HermesAdapter: HarnessAdapter {

    let harnessID = "hermes"

    var delivery: DeliveryKind {
        .directory(DirectoryDelivery(
            targetLabel: "Hermes home",
            discoverTargets: { Self.homeTarget().map { [$0] } ?? [] },
            noTargetGuidance: """
            Hermes isn't installed (no ~/.hermes directory). Install per the adapter \
            spec: clone NousResearch/hermes-agent and run \
            `bash scripts/install.sh --skip-setup --skip-browser`, then reload.
            """,
            postPush: { target, result in
                await Self.tightenPermissions(home: target.url, result: result)
            },
            healthProbe: HealthProbe(label: "Hermes dashboard",
                                     url: "http://127.0.0.1:9119/")))
    }

    /// `~/.hermes` as a push target when it exists.
    static func homeTarget() -> PushTargetOption? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".hermes")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return PushTargetOption(id: "hermes-home", displayName: "~/.hermes",
                                url: URL(fileURLWithPath: path))
    }

    /// Post-push: the whole ~/.hermes tree is PII — tighten permissions per the spec
    /// (chmod 700 on the home, 600 on the instruction files we wrote + .env).
    static func tightenPermissions(home: URL, result: BuildResult) async -> [String] {
        var log: [String] = []
        let chmod = "/bin/chmod"
        let r1 = await OpenClawService.run(chmod, ["700", home.path])
        log.append(r1.exitCode == 0 ? "✓ chmod 700 \(home.path)" : "✗ chmod 700 failed: \(r1.stderr)")

        var files = result.artifacts
            .filter { !$0.relativePath.contains("/") }   // top-level instruction files
            .map { home.appendingPathComponent($0.relativePath).path }
        let env = home.appendingPathComponent(".env").path
        if FileManager.default.fileExists(atPath: env) { files.append(env) }
        if !files.isEmpty {
            let r2 = await OpenClawService.run(chmod, ["600"] + files)
            log.append(r2.exitCode == 0
                       ? "✓ chmod 600 on \(files.count) instruction file(s)"
                       : "✗ chmod 600 failed: \(r2.stderr)")
        }
        return log
    }

    // MARK: Build

    func build(from store: CanonicalStore) -> BuildResult {
        var result = BuildResult()

        buildSoul(from: store, into: &result)
        buildAgents(from: store, into: &result)
        buildMemory(from: store, into: &result)
        buildSkills(from: store, into: &result)
        noteConnections(from: store, into: &result)

        if result.artifacts.isEmpty {
            result.warnings.append("Nothing selected to build. Check at least one Identity, Context, Skill, or Memory file in the browser.")
        }
        return result
    }

    // MARK: Identity → SOUL.md (same section renames as OpenClaw, per the spec)

    private func buildSoul(from store: CanonicalStore, into result: inout BuildResult) {
        let identities = store.includedFiles(.identity)
        guard let file = identities.first else {
            result.warnings.append("No Identity file selected — SOUL.md not generated. Identity is the foundation layer.")
            return
        }
        if identities.count > 1 {
            result.warnings.append("Multiple Identity files selected; only \(file.filename) was used for SOUL.md.")
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

        result.artifacts.append(BuildArtifact(
            relativePath: "SOUL.md",
            contents: out.trimmingCharacters(in: .newlines) + "\n",
            sourceDescription: "Identity ← \(file.filename)",
            designation: file.designation))
    }

    // MARK: Context (+ working memory) → AGENTS.md

    private func buildAgents(from store: CanonicalStore, into result: inout BuildResult) {
        let ctx = store.includedFiles(.context)
        let working = workingMemoryFile(in: store)
        guard !ctx.isEmpty || working != nil else {
            result.warnings.append("No Context file selected — AGENTS.md not generated.")
            return
        }

        let sorted = AdapterHelpers.sortedContext(ctx)
        var out = ""
        out += "<!-- Generated by Personal OS Studio · Hermes adapter -->\n"
        out += "> SOUL.md rules take precedence over anything below.\n\n"

        var strongest = Designation.pub
        for file in sorted {
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

        // Canonical working memory appends here (never into ~/.hermes/sessions/).
        if let working {
            let raw = store.read(working)
            let (_, body) = Frontmatter.split(raw)
            let parsed = MarkdownSections.parse(body)
            if working.designation.strength > strongest.strength { strongest = working.designation }
            out += "# Working memory\n\n"
            if !parsed.banner.isEmpty { out += AdapterHelpers.firstBlockquoteLine(parsed.banner) + "\n\n" }
            for (heading, sectionBody) in parsed.sections {
                if AdapterHelpers.droppedSections.contains(heading.lowercased()) { continue }
                out += "### \(heading)\n\n\(sectionBody)\n\n"
            }
        }

        result.artifacts.append(BuildArtifact(
            relativePath: "AGENTS.md",
            contents: out.trimmingCharacters(in: .newlines) + "\n",
            sourceDescription: "Context ← \(sorted.map(\.filename).joined(separator: ", "))"
                + (working != nil ? " + \(working!.filename)" : ""),
            designation: strongest))
    }

    private func workingMemoryFile(in store: CanonicalStore) -> CanonicalFile? {
        store.includedFiles(.memory).first {
            !$0.isTemplate && $0.filename.lowercased().hasPrefix("working")
        }
    }

    // MARK: Memory → MEMORY.md + memories/<name>.md

    private func buildMemory(from store: CanonicalStore, into result: inout BuildResult) {
        let mem = store.includedFiles(.memory)

        if let index = mem.first(where: { $0.filename.uppercased().contains("MEMORY") }) {
            let raw = store.read(index)
            let (_, body) = Frontmatter.split(raw)
            let contents = body.trimmingCharacters(in: .newlines) + "\n"
            if contents.components(separatedBy: "\n").count > 200 {
                result.warnings.append("MEMORY.md exceeds 200 lines — Hermes reads it every message; trim the index.")
            }
            result.artifacts.append(BuildArtifact(
                relativePath: "MEMORY.md",
                contents: contents,
                sourceDescription: "Memory index ← \(index.filename)",
                designation: index.designation))
        }

        // Persistent entries land in memories/ (Hermes path), not memory/.
        let entries = mem.filter { $0.entryType != nil && $0.name != nil }
        for file in entries {
            guard let name = file.name else { continue }
            let raw = store.read(file)
            let (fields, body) = Frontmatter.split(raw)
            let parsed = MarkdownSections.parse(body)
            let entryBody = parsed.section("Entry") ?? body

            var out = "---\n"
            out += "name: \(name)\n"
            if let et = fields["entry_type"] { out += "entry_type: \(et)\n" }
            if let d = fields["description"] { out += "description: \(d)\n" }
            out += "---\n\n"
            if !parsed.banner.isEmpty { out += AdapterHelpers.firstBlockquoteLine(parsed.banner) + "\n\n" }
            out += entryBody.trimmingCharacters(in: .newlines) + "\n"

            result.artifacts.append(BuildArtifact(
                relativePath: "memories/\(name).md",
                contents: out,
                sourceDescription: "Memory ← \(file.filename)",
                designation: file.designation))
        }
    }

    // MARK: Skills → skills/<name>/SKILL.md

    private func buildSkills(from store: CanonicalStore, into result: inout BuildResult) {
        let skills = AdapterHelpers.sortedSkills(
            store.includedFiles(.skills).filter { !$0.isTemplate && $0.name != nil })

        for file in skills {
            guard let name = file.name else { continue }
            let raw = store.read(file)
            let (fields, body) = Frontmatter.split(raw)
            let parsed = MarkdownSections.parse(body)

            let trigger = parsed.section("Trigger") ?? ""
            let description = AdapterHelpers.firstSentence(trigger)

            var out = "---\n"
            out += "name: \(name)\n"
            out += "description: \(description)\n"
            out += "---\n\n"
            out += AdapterHelpers.provenanceComment(fields) + "\n\n"
            if !parsed.banner.isEmpty { out += AdapterHelpers.firstBlockquoteLine(parsed.banner) + "\n\n" }
            for keep in ["Inputs", "Procedure", "Output"] {
                if let s = parsed.section(keep) {
                    out += "## \(keep)\n\n\(s)\n\n"
                }
            }

            result.artifacts.append(BuildArtifact(
                relativePath: "skills/\(name)/SKILL.md",
                contents: out.trimmingCharacters(in: .newlines) + "\n",
                sourceDescription: "Skill ← \(file.filename)",
                designation: file.designation))
        }
    }

    // MARK: Connections (guidance only)

    private func noteConnections(from store: CanonicalStore, into result: inout BuildResult) {
        let conns = store.includedFiles(.connections).filter { !$0.isTemplate }
        guard !conns.isEmpty else { return }
        result.warnings.append("Connections are configured in ~/.hermes/config.yaml (mcp:) and ~/.hermes/.env, not workspace files. \(conns.count) connection file(s) selected — register them manually per the Hermes adapter; Studio does not edit config.yaml.")
    }
}
