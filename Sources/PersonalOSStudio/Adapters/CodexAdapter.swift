import Foundation

/// Implements the Codex adapter documented in `agent_os/adapters/codex.md`
/// (v1.1.0, pinned Codex CLI 0.133.0).
///
/// Codex reads **one repo-scoped `AGENTS.md`** (walking CWD up to the git repo root —
/// there is no user-level always-on file), so this adapter concatenates Identity +
/// Context + agent job + high-signal memory into a single AGENTS.md pushed to a
/// user-chosen git repo root, and renders personal-scope skills into Codex's
/// first-class skills directory at `~/.codex/skills/<name>/SKILL.md`.
struct CodexAdapter: HarnessAdapter {

    let harnessID = "codex"

    static let repoDefaultsKey = "codex.repoRoot"

    var delivery: DeliveryKind {
        .directory(DirectoryDelivery(
            targetLabel: "Git repo (AGENTS.md)",
            discoverTargets: { Self.rememberedRepoTarget().map { [$0] } ?? [] },
            noTargetGuidance: "Codex reads AGENTS.md from a git repo root — choose the personal/access-controlled repo Codex runs in.",
            postPush: { target, result in
                Self.stageExcludeEntries(repoRoot: target.url, artifacts: result.artifacts)
            },
            healthProbe: nil,
            readiness: { Self.detectInstall() },
            customTarget: CustomTargetSpec(
                buttonLabel: "Choose git repo…",
                panelMessage: "Choose the git repository root Codex will run in (AGENTS.md is written there)",
                validate: { url in
                    FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
                        ? nil
                        : "Not a git repository root (no .git found) — Codex only loads AGENTS.md inside a git repo."
                },
                defaultsKey: Self.repoDefaultsKey),
            partition: { artifact in
                // Personal-scope skills live in Codex home; everything else
                // (AGENTS.md + project-scope skills under .codex/) goes to the repo.
                if artifact.relativePath.hasPrefix("skills/") {
                    return .fixed(Self.codexSkillsDir(), label: "~/.codex/skills")
                }
                return .target
            }))
    }

    /// The last user-confirmed repo root, if it is still a git repo.
    static func rememberedRepoTarget() -> PushTargetOption? {
        guard let path = UserDefaults.standard.string(forKey: repoDefaultsKey), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else { return nil }
        return PushTargetOption(id: "codex-repo", displayName: url.lastPathComponent, url: url)
    }

    static func codexSkillsDir() -> URL {
        URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".codex/skills"))
    }

    /// Read-only install detection: codex binary on PATH-ish locations + ~/.codex home.
    static func detectInstall() -> (ok: Bool, message: String) {
        let fm = FileManager.default
        let binaries = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            (NSHomeDirectory() as NSString).appendingPathComponent(".npm-global/bin/codex"),
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/codex"),
        ]
        let bin = binaries.first { fm.isExecutableFile(atPath: $0) }
        let home = fm.fileExists(atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".codex"))
        if let bin, home { return (true, "codex found at \(bin)") }
        if bin != nil { return (false, "codex binary found but no ~/.codex — run `codex login` once") }
        return (false, "codex not installed — `brew install codex` or `npm install -g @openai/codex`")
    }

    /// Exclusion patterns for a push's repo-bound artifacts, designation-aware: every
    /// artifact that lands in the repo (not `skills/` — those go to ~/.codex) and
    /// carries **PII** yields an entry — top-level files as `/NAME`, directory-rooted
    /// ones as `/dir/` — plus Studio backups always. Enterprise/Public project-scope
    /// skills under `.codex/` stay committable per the adapter spec ("subject to
    /// designation").
    static func excludeEntries(for artifacts: [BuildArtifact]) -> Set<String> {
        var entries: Set<String> = ["*.bak-studio"]
        for artifact in artifacts
        where !artifact.relativePath.hasPrefix("skills/") && artifact.designation == .pii {
            let parts = artifact.relativePath.components(separatedBy: "/")
            entries.insert(parts.count == 1 ? "/\(parts[0])" : "/\(parts[0])/")
        }
        return entries
    }

    /// Idempotently stage the push's exclusion entries in `<repo>/.git/info/exclude`
    /// (per-clone ignore — never the shared .gitignore): harness renders of PII must
    /// never be committable. Returns log lines.
    static func stageExcludeEntries(repoRoot: URL, artifacts: [BuildArtifact]) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: repoRoot.appendingPathComponent(".git").path) else {
            return ["✗ not a git repo — exclude entries not staged"]
        }
        let entries = excludeEntries(for: artifacts)
        let excludeURL = repoRoot.appendingPathComponent(".git/info/exclude")
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        let existingLines = Set(existing.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) })
        let missing = entries.subtracting(existingLines).sorted()
        guard !missing.isEmpty else {
            return ["· all \(entries.count) exclude entries already in .git/info/exclude"]
        }
        do {
            try fm.createDirectory(at: excludeURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let head = existing.trimmingCharacters(in: .newlines)
            let updated = (head.isEmpty ? "" : head + "\n") + missing.joined(separator: "\n") + "\n"
            try updated.write(to: excludeURL, atomically: true, encoding: .utf8)
            return ["✓ added \(missing.joined(separator: ", ")) to .git/info/exclude (local-only ignore)"]
        } catch {
            return ["✗ could not update .git/info/exclude: \(error.localizedDescription)"]
        }
    }

    // MARK: Build

    func build(from store: CanonicalStore) -> BuildResult {
        var result = BuildResult()

        buildAgentsFile(from: store, into: &result)
        buildSkills(from: store, into: &result)
        noteConnections(from: store, into: &result)

        if result.artifacts.isEmpty {
            result.warnings.append("Nothing selected to build. Check at least one Identity, Context, or Skill file in the browser.")
        }
        return result
    }

    // MARK: Identity + Context + Agent + memory → AGENTS.md

    private func buildAgentsFile(from store: CanonicalStore, into result: inout BuildResult) {
        let identities = store.includedFiles(.identity)
        let ctx = store.includedFiles(.context)
        let agents = store.includedFiles(.agents).filter { !$0.isTemplate }
        guard identities.first != nil || !ctx.isEmpty else {
            result.warnings.append("No Identity or Context file selected — AGENTS.md not generated.")
            return
        }

        var strongest = Designation.pub
        var sources: [String] = []
        var out = ""

        // Identity block first: banner, provenance, precedence preamble, renamed H2s.
        if let file = identities.first {
            if identities.count > 1 {
                result.warnings.append("Multiple Identity files selected; only \(file.filename) was used.")
            }
            let raw = store.read(file)
            let (fields, body) = Frontmatter.split(raw)
            let parsed = MarkdownSections.parse(body)
            strongest = file.designation
            sources.append(file.filename)

            out += AdapterHelpers.provenanceComment(fields) + "\n\n"
            out += AdapterHelpers.bannerOrDefault(parsed.banner, designation: file.designation) + "\n\n"
            out += "*Identity rules below take precedence over Context and any nested AGENTS.md.*\n\n"
            for (heading, sectionBody) in parsed.sections {
                if AdapterHelpers.droppedSections.contains(heading.lowercased()) { continue }
                out += "## \(AdapterHelpers.renameIdentityHeading(heading))\n\n\(sectionBody)\n\n"
            }
        } else {
            out += "> **Classification: PII** — personal instructions. Do not share.\n\n"
            out += "*Identity rules below take precedence over Context and any nested AGENTS.md.*\n\n"
        }

        // High-signal persistent memory inlines into the identity region.
        appendEntries(from: store, types: ["user"], header: "## Persistent facts",
                      to: &out, strongest: &strongest)
        appendEntries(from: store, types: ["feedback"], header: "## Feedback",
                      to: &out, strongest: &strongest)

        out += "---\n\n"

        // Context sections (role → domain → team).
        for file in AdapterHelpers.sortedContext(ctx) {
            let raw = store.read(file)
            let (_, body) = Frontmatter.split(raw)
            let parsed = MarkdownSections.parse(body)
            if file.designation.strength > strongest.strength { strongest = file.designation }
            sources.append(file.filename)

            let type = (file.contextType ?? "context").capitalized
            out += "# \(type) context\n\n"
            if !parsed.banner.isEmpty { out += AdapterHelpers.firstBlockquoteLine(parsed.banner) + "\n\n" }
            for (heading, sectionBody) in parsed.sections {
                if AdapterHelpers.droppedSections.contains(heading.lowercased()) { continue }
                out += "### \(heading)\n\n\(sectionBody)\n\n"
            }
        }

        // Active agent job description(s).
        for agent in agents {
            let raw = store.read(agent)
            let (_, body) = Frontmatter.split(raw)
            let parsed = MarkdownSections.parse(body)
            if agent.designation.strength > strongest.strength { strongest = agent.designation }
            sources.append(agent.filename)
            out += "# Active agent: \(agent.name ?? agent.title)\n\n"
            if !parsed.banner.isEmpty { out += AdapterHelpers.firstBlockquoteLine(parsed.banner) + "\n\n" }
            for (heading, sectionBody) in parsed.sections {
                if AdapterHelpers.droppedSections.contains(heading.lowercased()) { continue }
                out += "### \(heading)\n\n\(sectionBody)\n\n"
            }
        }

        // Project/reference entries are project-scoped — this AGENTS.md is the project.
        appendEntries(from: store, types: ["project", "reference"], header: "# Project memory",
                      to: &out, strongest: &strongest)

        let contents = out.trimmingCharacters(in: .newlines) + "\n"
        let words = contents.split(whereSeparator: \.isWhitespace).count
        if words > 3_000 {
            result.warnings.append("AGENTS.md is \(words) words — aim under 3,000 to leave Codex context budget for the task (truncation order per the adapter contract).")
        }

        result.artifacts.append(BuildArtifact(
            relativePath: "AGENTS.md",
            contents: contents,
            sourceDescription: "Identity+Context+Agent ← \(sources.joined(separator: ", "))",
            designation: strongest))
    }

    private func appendEntries(from store: CanonicalStore, types: [String], header: String,
                               to out: inout String, strongest: inout Designation) {
        let entries = store.includedFiles(.memory)
            .filter { $0.entryType.map(types.contains) == true && $0.name != nil }
        guard !entries.isEmpty else { return }
        out += "\(header)\n\n"
        for file in entries {
            let (_, body) = Frontmatter.split(store.read(file))
            let parsed = MarkdownSections.parse(body)
            let entryBody = (parsed.section("Entry") ?? body).trimmingCharacters(in: .whitespacesAndNewlines)
            out += "**\(file.name ?? file.filename)**: \(entryBody)\n\n"
            if file.designation.strength > strongest.strength { strongest = file.designation }
        }
    }

    // MARK: Skills → SKILL.md (personal → ~/.codex/skills; project → <repo>/.codex/skills)

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
            out += "metadata:\n"
            out += "  short-description: \(name.replacingOccurrences(of: "-", with: " "))\n"
            out += "---\n\n"
            out += AdapterHelpers.provenanceComment(fields) + "\n\n"
            if !parsed.banner.isEmpty { out += AdapterHelpers.firstBlockquoteLine(parsed.banner) + "\n\n" }
            for keep in ["Inputs", "Procedure", "Output"] {
                if let s = parsed.section(keep) {
                    out += "## \(keep)\n\n\(s)\n\n"
                }
            }

            // scope: project → repo-scoped .codex/skills (subject to designation);
            // everything else → user-level ~/.codex/skills (partitioned at push).
            let isProject = file.scope == "project"
            let relative = isProject ? ".codex/skills/\(name)/SKILL.md" : "skills/\(name)/SKILL.md"

            result.artifacts.append(BuildArtifact(
                relativePath: relative,
                contents: out.trimmingCharacters(in: .newlines) + "\n",
                sourceDescription: "Skill ← \(file.filename)\(isProject ? " (project-scoped)" : "")",
                designation: file.designation))
        }
    }

    // MARK: Connections (guidance only)

    private func noteConnections(from store: CanonicalStore, into result: inout BuildResult) {
        let conns = store.includedFiles(.connections).filter { !$0.isTemplate }
        guard !conns.isEmpty else { return }
        result.warnings.append("Connections are configured in ~/.codex/config.toml ([mcp_servers.<name>]) — run `codex mcp` to manage. \(conns.count) connection file(s) selected; register them manually per the Codex adapter. Studio does not edit config.toml.")
    }
}
