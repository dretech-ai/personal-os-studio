import Foundation
import CryptoKit

/// Headless verification of the OpenClaw adapter against whatever canonical repo
/// the process is launched in. Run with `--selftest`.
enum SelfTest {
    static func run() {
        let cwd = FileManager.default.currentDirectoryPath
        let root = URL(fileURLWithPath: cwd)
        print("== Personal OS Studio self-test ==")
        print("canonical root: \(root.path)")

        // Opt into examples here so the headless transform has content to build
        // even when no real personal content exists on this machine.
        let store = CanonicalStore(rootURL: root, includeExamples: true)
        print("valid Agent OS root: \(store.isValidRoot)")
        for layer in Layer.allCases {
            let files = store.files(layer)
            print("  \(layer.title): \(files.count) file(s)")
        }

        // Include the fictional examples so we exercise a full transform even
        // when no private content exists on this machine.
        for layer in Layer.allCases {
            for f in store.files(layer) where f.isExample { f.include = true }
        }

        let result = OpenClawAdapter().build(from: store)
        print("\n-- generated \(result.artifacts.count) artifact(s), effective designation \(result.effectiveDesignation.label) --")
        for art in result.artifacts {
            print("\n### \(art.relativePath)  [\(art.byteCount)B]  (\(art.sourceDescription))")
            let preview = art.contents.components(separatedBy: "\n").prefix(8).joined(separator: "\n")
            print(preview)
        }
        if !result.warnings.isEmpty {
            print("\n-- warnings --")
            result.warnings.forEach { print("  ! \($0)") }
        }

        // Optional: exercise the push path against a scratch workspace.
        if let idx = CommandLine.arguments.firstIndex(of: "--pushtest"),
           idx + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ws = OpenClawWorkspace(id: dir.lastPathComponent, url: dir)
            let svc = OpenClawService(stateDir: dir.deletingLastPathComponent())
            print("\n-- push test → \(dir.path) --")
            let log = svc.push(result, to: ws, backup: true)
            log.forEach { print("  \($0)") }
        }

        print("\n== self-test done ==")
    }

    /// Headless verification of the Hermes adapter (`adapters/hermes.md`): build with
    /// the fictional examples enabled and assert the spec's mapping — SOUL.md section
    /// renames, memories/ paths, MEMORY.md ≤ 200 lines. Pass `--pushtest <dir>` too to
    /// exercise the push + permission-tightening path into a scratch dir. No network.
    static func hermesTest() {
        let cwd = FileManager.default.currentDirectoryPath
        let store = CanonicalStore(rootURL: URL(fileURLWithPath: cwd), includeExamples: true)
        print("== Hermes adapter self-test ==")
        print("canonical root: \(cwd)")

        for layer in Layer.allCases {
            for f in store.files(layer) where f.isExample { f.include = true }
        }

        let result = HermesAdapter().build(from: store)
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("  [\(ok ? "ok" : "FAIL")] \(what)")
            if !ok { failures += 1 }
        }

        let soul = result.artifacts.first { $0.relativePath == "SOUL.md" }
        expect(soul != nil, "SOUL.md generated")
        if let soul {
            expect(soul.contents.contains("## Principles"), "identity heading renamed → ## Principles")
            expect(!soul.contents.contains("## Operating Principles"), "no un-renamed Operating Principles")
            expect(soul.contents.hasPrefix(">"), "classification banner first")
        }
        let agents = result.artifacts.first { $0.relativePath == "AGENTS.md" }
        expect(agents != nil, "AGENTS.md generated")
        if let agents {
            expect(agents.contents.contains("SOUL.md rules take precedence"), "precedence preamble present")
            let role = agents.contents.range(of: "# Role context")
            let domain = agents.contents.range(of: "# Domain context")
            if let r = role, let d = domain {
                expect(r.lowerBound < d.lowerBound, "role before domain")
            }
        }
        if let memoryIndex = result.artifacts.first(where: { $0.relativePath == "MEMORY.md" }) {
            expect(memoryIndex.contents.components(separatedBy: "\n").count <= 200, "MEMORY.md ≤ 200 lines")
        }
        expect(result.artifacts.contains { $0.relativePath.hasPrefix("memories/") },
               "persistent entries under memories/ (Hermes path)")
        expect(result.artifacts.contains { $0.relativePath.hasPrefix("skills/") && $0.relativePath.hasSuffix("SKILL.md") },
               "skills under skills/<name>/SKILL.md")

        // Optional: exercise push + chmod into a scratch dir.
        if let idx = CommandLine.arguments.firstIndex(of: "--pushtest"),
           idx + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            print("\n-- hermes push test → \(dir.path) --")
            let log = DirectoryPusher.push(result, into: dir, backup: true)
            log.forEach { print("  \($0)") }
            let sem = DispatchSemaphore(value: 0)
            Task {
                let chmodLog = await HermesAdapter.tightenPermissions(
                    home: dir,
                    result: result)
                chmodLog.forEach { print("  \($0)") }
                sem.signal()
            }
            sem.wait()
        }

        print("\n== hermes self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
        exit(failures == 0 ? 0 : 1)
    }

    /// Headless verification of the Claude Cowork adapter (`adapters/claude-cowork.md`):
    /// paste-block mapping assertions + the length-pressure trimming rules. Pass
    /// `--pushtest <dir>` to also dump the blocks as files (for clipboard round-trip
    /// checks with pbcopy/pbpaste). No network; never touches Claude Desktop config.
    static func coworkTest() {
        let cwd = FileManager.default.currentDirectoryPath
        let store = CanonicalStore(rootURL: URL(fileURLWithPath: cwd), includeExamples: true)
        print("== Claude Cowork adapter self-test ==")
        print("canonical root: \(cwd)")

        for layer in Layer.allCases {
            for f in store.files(layer) where f.isExample { f.include = true }
        }

        let result = CoworkAdapter().build(from: store)
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("  [\(ok ? "ok" : "FAIL")] \(what)")
            if !ok { failures += 1 }
        }

        expect(result.artifacts.count == 2, "exactly two paste blocks (got \(result.artifacts.count))")

        let global = result.artifacts.first { $0.relativePath == CoworkAdapter.globalBlock }
        expect(global != nil, "Global instructions block generated")
        if let global {
            expect(global.contents.hasPrefix(">"), "Global: classification banner first")
            expect(global.contents.contains("<!-- owner:"), "Global: provenance comment present")
            expect(global.contents.contains("## Principles"), "Global: identity headings renamed")
            expect(!global.contents.contains("## Operating Principles"), "Global: no un-renamed headings")
        }

        let folder = result.artifacts.first { $0.relativePath == CoworkAdapter.folderBlock }
        expect(folder != nil, "Folder instructions block generated")
        if let folder {
            let role = folder.contents.range(of: "# Role context")
            let domain = folder.contents.range(of: "# Domain context")
            expect(role != nil, "Folder: role context present")
            if let r = role, let d = domain { expect(r.lowerBound < d.lowerBound, "Folder: role before domain") }
            expect(folder.contents.contains("# Active agent:"), "Folder: active agent job included")
        }

        // Length-pressure unit check: a synthetic over-long block drops sections in
        // spec order and never touches Principles/Boundaries.
        var synthetic = "> banner\n\n## Agent\n\nx\n\n## Principles\n\np\n\n## Boundaries\n\nb\n\n"
        synthetic += "## Style\n\n" + String(repeating: "s", count: 9_000) + "\n\n"
        synthetic += "## Output\n\no\n\n## Escalation\n\ne\n"
        let (trimmed, dropped) = CoworkAdapter.applyLengthPressure(synthetic)
        expect(dropped.first == "Style", "length pressure drops Style first (got \(dropped))")
        expect(trimmed.contains("## Principles") && trimmed.contains("## Boundaries"),
               "length pressure never drops Principles/Boundaries")

        // Optional: dump blocks as files for clipboard round-trip verification.
        if let idx = CommandLine.arguments.firstIndex(of: "--pushtest"),
           idx + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for block in result.artifacts {
                let name = block.relativePath.replacingOccurrences(of: " ", with: "-") + ".md"
                try? block.contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
                print("  dumped \(name) (\(block.byteCount)B)")
            }
        }

        print("\n== cowork self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
        exit(failures == 0 ? 0 : 1)
    }

    /// Headless verification of the Codex adapter (`adapters/codex.md` v1.1.0):
    /// single concatenated AGENTS.md layout, skill frontmatter shape, and — with
    /// `--pushtest <dir>` pointing at a scratch **git repo** — the partitioned push
    /// plus idempotent `.git/info/exclude` staging. No network; never touches ~/.codex.
    static func codexTest() {
        let cwd = FileManager.default.currentDirectoryPath
        let store = CanonicalStore(rootURL: URL(fileURLWithPath: cwd), includeExamples: true)
        print("== Codex adapter self-test ==")
        print("canonical root: \(cwd)")

        for layer in Layer.allCases {
            for f in store.files(layer) where f.isExample { f.include = true }
        }

        let result = CodexAdapter().build(from: store)
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("  [\(ok ? "ok" : "FAIL")] \(what)")
            if !ok { failures += 1 }
        }

        let agentsFiles = result.artifacts.filter { $0.relativePath == "AGENTS.md" }
        expect(agentsFiles.count == 1, "exactly one AGENTS.md (repo-scoped single file)")
        if let agents = agentsFiles.first {
            expect(agents.contents.contains("Identity rules below take precedence"),
                   "precedence preamble present")
            expect(agents.contents.contains("## Principles"), "identity headings renamed")
            expect(agents.contents.contains("---"), "identity/context divider present")
            let role = agents.contents.range(of: "# Role context")
            let domain = agents.contents.range(of: "# Domain context")
            if let r = role, let d = domain { expect(r.lowerBound < d.lowerBound, "role before domain") }
            expect(agents.contents.contains("# Active agent:"), "active agent job included")
            expect(agents.contents.contains("**"), "persistent memory inlined")
        }

        let skills = result.artifacts.filter { $0.relativePath.hasSuffix("SKILL.md") }
        expect(!skills.isEmpty, "skills generated")
        if let skill = skills.first {
            expect(skill.contents.contains("metadata:") && skill.contents.contains("short-description:"),
                   "Codex skill frontmatter has metadata.short-description")
            expect(skill.contents.contains("## Procedure"), "skill Procedure kept")
        }

        // Commit-exclusion derivation (F15.2): every repo-bound PII artifact yields an
        // entry; ~/.codex-bound skills never do; non-PII repo artifacts stay committable.
        let fakeArtifacts = [
            BuildArtifact(relativePath: "AGENTS.md", contents: "x",
                          sourceDescription: "Identity ← identity.md", designation: .pii),
            BuildArtifact(relativePath: "memory/pool.md", contents: "x",
                          sourceDescription: "Memory ← pool.md", designation: .pii),
            BuildArtifact(relativePath: ".codex/skills/qbr/SKILL.md", contents: "x",
                          sourceDescription: "Skill ← qbr.md (project-scoped)", designation: .enterprise),
            BuildArtifact(relativePath: "skills/personal/SKILL.md", contents: "x",
                          sourceDescription: "Skill ← personal.md", designation: .pii),
        ]
        let entries = CodexAdapter.excludeEntries(for: fakeArtifacts)
        expect(entries.contains("/AGENTS.md"), "exclude derives /AGENTS.md")
        expect(entries.contains("/memory/"), "exclude derives /memory/ for PII memory artifacts")
        expect(entries.contains("*.bak-studio"), "exclude always covers Studio backups")
        expect(!entries.contains("/.codex/"), "Enterprise project-scope skill stays committable")
        expect(!entries.contains { $0.hasPrefix("/skills") }, "~/.codex-bound skills derive no entry")
        // The real example build: every repo-bound PII artifact is covered.
        let realEntries = CodexAdapter.excludeEntries(for: result.artifacts)
        let uncovered = result.artifacts.filter {
            !$0.relativePath.hasPrefix("skills/") && $0.designation == .pii
                && !realEntries.contains("/\($0.relativePath.components(separatedBy: "/")[0])")
                && !realEntries.contains("/\($0.relativePath.components(separatedBy: "/")[0])/")
        }
        expect(uncovered.isEmpty, "every repo-bound PII artifact from the real build is covered")

        // Optional: partitioned push into a scratch git repo + exclude idempotency.
        if let idx = CommandLine.arguments.firstIndex(of: "--pushtest"),
           idx + 1 < CommandLine.arguments.count {
            let repo = URL(fileURLWithPath: CommandLine.arguments[idx + 1])
            let skillsDir = repo.appendingPathComponent("codex-skills-scratch")
            print("\n-- codex push test → \(repo.path) --")

            // AGENTS.md (+ any project-scope skills) into the repo root.
            var repoResult = BuildResult()
            repoResult.artifacts = result.artifacts.filter { !$0.relativePath.hasPrefix("skills/") }
            DirectoryPusher.push(repoResult, into: repo, backup: true).forEach { print("  \($0)") }

            // Personal skills into a scratch stand-in for ~/.codex/skills.
            var skillResult = BuildResult()
            skillResult.artifacts = result.artifacts.filter { $0.relativePath.hasPrefix("skills/") }
            DirectoryPusher.push(skillResult, into: skillsDir, backup: true).forEach { print("  \($0)") }

            // Exclude staging must cover all PII artifacts and stay idempotent.
            CodexAdapter.stageExcludeEntries(repoRoot: repo, artifacts: result.artifacts).forEach { print("  \($0)") }
            CodexAdapter.stageExcludeEntries(repoRoot: repo, artifacts: result.artifacts).forEach { print("  \($0)") }
            let exclude = (try? String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)) ?? ""
            let lines = exclude.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            for entry in CodexAdapter.excludeEntries(for: result.artifacts) {
                let count = lines.filter { $0 == entry }.count
                expect(count == 1, "\(entry) staged exactly once (got \(count))")
            }
        }

        print("\n== codex self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
        exit(failures == 0 ? 0 : 1)
    }

    /// Headless verification of the bootstrap wizard. Structural assertions always run
    /// (step resolution/order, offer condition, carry-forward cap). With `--live`, also
    /// drives a real two-doc wizard run against local Ollama (llama3.2) — run it from a
    /// SCRATCH copy of the canonical repo, because Save All writes into the cwd repo.
    static func bootstrapTest() {
        let live = CommandLine.arguments.contains("--live")
        Task { @MainActor in
            let cwd = FileManager.default.currentDirectoryPath
            let store = CanonicalStore(rootURL: URL(fileURLWithPath: cwd))
            print("== Bootstrap wizard self-test ==")
            print("canonical root: \(cwd)  (live: \(live))")

            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            // Step resolution + order.
            let steps = BootstrapEngine.resolveSteps(in: store)
            expect(steps.count == 5, "5 wizard steps resolved (got \(steps.count))")
            let expectedOrder = ["identity/identity.md", "context/role.md", "context/domain.md",
                                 "context/team.md", "memory/MEMORY.md"]
            expect(steps.map(\.suggestedRelativePath) == expectedOrder,
                   "steps in canonical order (got \(steps.map(\.suggestedRelativePath)))")

            // Carry-forward cap.
            let engine = InterviewEngine(ownerEmail: "test@example.com", today: "2026-01-01")
            let boot = BootstrapEngine(engine: engine)
            boot.seedFactsForTesting([
                (doc: "My Identity", answers: [String(repeating: "a", count: 2_000)]),
                (doc: "Role context", answers: [String(repeating: "b", count: 2_000)]),
            ])
            let block = boot.carryForwardBlock()
            expect(!block.isEmpty && block.count <= BootstrapEngine.carryForwardCap,
                   "carry-forward capped at \(BootstrapEngine.carryForwardCap) (got \(block.count))")

            // Live two-doc run against Ollama.
            if live {
                let provider = OllamaProvider(baseURL: "http://localhost:11434", model: "llama3.2")
                await boot.start(provider: provider, store: store, personName: "Andre Leuven")
                let answer = "I'm an engineering manager at UniFirst focused on IT systems; my top priority is reliable automation and clear weekly reporting."

                for docIndex in 0..<2 {
                    expect(boot.phase == .interviewing, "doc \(docIndex + 1): wizard interviewing")
                    guard case .asking = engine.phase else {
                        expect(false, "doc \(docIndex + 1): engine asking (got \(engine.phase))")
                        break
                    }
                    engine.input = answer
                    await engine.send()
                    await boot.finishCurrentDoc()
                }
                expect(boot.completed.count == 2, "two docs completed (got \(boot.completed.count))")
                if boot.completed.count == 2 {
                    expect(!boot.carryForwardBlock().isEmpty, "carry-forward non-empty after docs")
                    for doc in boot.completed {
                        expect(doc.draft.contains("owner:"), "\(doc.id): frontmatter owner present")
                        expect(!doc.draft.contains("<Your name>"), "\(doc.id): no <Your name> token")
                    }
                }
                // Skip the remaining docs → review → save into the (scratch) repo.
                while boot.phase == .interviewing { await boot.skipCurrentDoc() }
                expect(boot.phase == .review, "review phase after skipping the rest")
                let log = boot.saveAll()
                log.forEach { print("  \($0)") }
                expect(log.filter { $0.hasPrefix("✓") }.count == 2, "both drafts saved")
                expect(store.fileExists(relativePath: "identity/identity.md"), "identity.md exists on disk")
            }

            print("\n== bootstrap self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()   // park the main thread; the MainActor task exits the process
    }

    /// Headless verification of provider response parsing (`--providertest`):
    /// Anthropic Messages responses are typed block arrays where text is NOT always
    /// first (adaptive-thinking models lead with a thinking block). Deterministic,
    /// no network.
    static func providerTest() {
        print("== provider parsing self-test ==")
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("  [\(ok ? "ok" : "FAIL")] \(what)")
            if !ok { failures += 1 }
        }

        // Sonnet-5 shape: thinking block first, then text.
        let thinkingFirst: [String: Any] = [
            "content": [
                ["type": "thinking", "thinking": ""],
                ["type": "text", "text": "What does your domain cover?"],
            ],
            "stop_reason": "end_turn",
        ]
        expect((try? AnthropicProvider.extractText(from: thinkingFirst)) == "What does your domain cover?",
               "text extracted when a thinking block leads")

        // Plain shape: text first (Opus/Haiku default).
        let plain: [String: Any] = [
            "content": [["type": "text", "text": "Hello."]],
            "stop_reason": "end_turn",
        ]
        expect((try? AnthropicProvider.extractText(from: plain)) == "Hello.",
               "text extracted from a plain response")

        // Multiple text blocks concatenate.
        let multi: [String: Any] = [
            "content": [
                ["type": "text", "text": "Part one."],
                ["type": "thinking", "thinking": ""],
                ["type": "text", "text": "Part two."],
            ],
            "stop_reason": "end_turn",
        ]
        expect((try? AnthropicProvider.extractText(from: multi)) == "Part one.\nPart two.",
               "multiple text blocks concatenated")

        // Refusal: no text blocks → actionable error naming the stop reason.
        let refusal: [String: Any] = ["content": [] as [[String: Any]], "stop_reason": "refusal"]
        do {
            _ = try AnthropicProvider.extractText(from: refusal)
            expect(false, "refusal raises an actionable error")
        } catch {
            expect("\(error)".lowercased().contains("refusal") || (error as? LLMError)?.errorDescription?.contains("refusal") == true,
                   "refusal raises an actionable error")
        }

        // Garbage → decoding error, not a crash.
        expect((try? AnthropicProvider.extractText(from: ["nope": true])) == nil,
               "missing content array raises decoding error")

        print("\n== provider self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
        exit(failures == 0 ? 0 : 1)
    }

    /// Headless verification of the refine flow: SemVer + guardrail unit assertions
    /// always run; with `--live`, drives a real refine of identity/identity.md against
    /// local Ollama — run from a SCRATCH canonical copy (the draft isn't saved, but
    /// keep test runs off the real repo anyway).
    static func refineTest() {
        let live = CommandLine.arguments.contains("--live")
        Task { @MainActor in
            let cwd = FileManager.default.currentDirectoryPath
            print("== Refine self-test ==")
            print("canonical root: \(cwd)  (live: \(live))")

            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            // SemVer basics.
            expect(SemVer("1.2.3") != nil && SemVer("1.2") == nil && SemVer("a.b.c") == nil, "semver parsing")
            expect(SemVer("0.1.0")!.bumpedMinor.description == "0.2.0", "minor bump")
            expect(SemVer("1.2.3")! > SemVer("1.2.2")! && SemVer("2.0.0")! > SemVer("1.9.9")!, "semver compare")

            // Guardrail: unbumped version + missing changelog entry get fixed.
            let badDraft = """
            ---
            title: T
            version: 0.1.0
            last_reviewed: 2020-01-01
            ---

            ## Body

            content

            ## Change Log

            - 2020-01-01 · v0.1.0 — initial
            """
            let fixed = InterviewEngine.enforceRefineGuardrail(
                draft: badDraft, originalVersion: "0.1.0", today: "2026-07-03")
            expect(fixed.contains("version: 0.2.0"), "guardrail bumps unbumped version")
            expect(fixed.contains("last_reviewed: 2026-07-03"), "guardrail sets last_reviewed to today")
            expect(fixed.contains("v0.2.0 — refined via interview"), "guardrail appends Change Log entry")
            expect(fixed.contains("v0.1.0 — initial"), "guardrail preserves prior entries")

            // Guardrail: a properly bumped draft passes through untouched (version-wise).
            let goodDraft = badDraft.replacingOccurrences(of: "version: 0.1.0", with: "version: 0.3.0")
                .replacingOccurrences(of: "- 2020-01-01 · v0.1.0 — initial",
                                      with: "- 2020-01-01 · v0.1.0 — initial\n- 2026-07-03 · v0.3.0 — update")
            let untouched = InterviewEngine.enforceRefineGuardrail(
                draft: goodDraft, originalVersion: "0.1.0", today: "2026-07-03")
            expect(untouched.contains("version: 0.3.0"), "guardrail keeps a valid model bump")

            // Validation findings (F08) are surfaced to the refine agent (F06 wiring):
            // the formatter renders each with severity + rule; a clean doc yields nothing.
            let sampleFindings = [
                Finding(severity: .error, rule: "banner.presence",
                        message: "no blockquote classification banner within the first 10 lines"),
                Finding(severity: .warning, rule: "review.stale",
                        message: "last_reviewed is older than the cadence window"),
            ]
            let findingsText = InterviewEngine.formatFindings(sampleFindings)
            expect(findingsText.contains("[error] banner.presence:")
                   && findingsText.contains("[warning] review.stale:"),
                   "findings formatter renders severities + rules for the refine prompt")
            expect(InterviewEngine.formatFindings([]).isEmpty, "clean doc yields no findings block")

            // Deterministic structural repair: a draft missing its banner + Classification
            // section is made compliant regardless of what the model produced.
            let bannerFinding = Finding(severity: .error, rule: "banner.presence",
                                        message: "no blockquote classification banner within the first 10 lines")
            let sectionFinding = Finding(severity: .error, rule: "sections.missing",
                                         message: "missing canonical section(s): Classification")
            let nonCompliant = """
            ---
            designation: PII
            version: 0.2.0
            ---

            ## Agent Identity

            - Name: Atlas
            """
            let repaired = Validator.repairStructure(
                draft: nonCompliant, findings: [bannerFinding, sectionFinding])
            expect(repaired.contains("> **Classification: PII**"), "repair injects the PII banner")
            expect(Validator.fenceAwareHeadings(of: repaired).first == "Classification",
                   "repair inserts ## Classification as the first section")
            expect(repaired.contains("designation: PII") && repaired.contains("## Agent Identity"),
                   "repair preserves frontmatter and existing sections")
            // Idempotent: re-running finds the doc compliant and changes nothing.
            expect(Validator.repairStructure(draft: repaired, findings: [bannerFinding, sectionFinding]) == repaired,
                   "repair is idempotent")
            // No findings → untouched.
            expect(Validator.repairStructure(draft: nonCompliant, findings: []) == nonCompliant,
                   "repair is a no-op when nothing was flagged")

            // Frontmatter normalization: a model can drop the opening --- (→ "Unknown"
            // classification + a wall of frontmatter errors). Restore it deterministically.
            let missingOpen = "title: T\ndesignation: PII\nversion: 0.1.0\n---\n\n## Body\n\ntext"
            let normalized = InterviewEngine.normalizeFrontmatter(missingOpen)
            expect(normalized.hasPrefix("---\ntitle: T"), "normalize restores the opening --- delimiter")
            expect(Frontmatter.split(normalized).0["designation"] == "PII",
                   "normalized frontmatter now parses (designation = PII)")
            let wellFormed = "---\ntitle: T\ndesignation: PII\n---\n\n## Body"
            expect(InterviewEngine.normalizeFrontmatter(wellFormed) == wellFormed,
                   "normalize is a no-op on well-formed frontmatter")
            let bodyRule = "Just prose.\n\n---\n\nA horizontal rule, not frontmatter."
            expect(InterviewEngine.normalizeFrontmatter(bodyRule) == bodyRule,
                   "normalize leaves non-YAML leading text alone")

            if live {
                let store = CanonicalStore(rootURL: URL(fileURLWithPath: cwd))
                guard let file = store.file(atRelativePath: "identity/identity.md") else {
                    expect(false, "identity/identity.md exists for live refine")
                    print("\n== refine self-test FAILED ==")
                    exit(1)
                }
                let originalVersion = file.version
                let engine = InterviewEngine(ownerEmail: "test@example.com", today: todayString())
                engine.configureRefine(provider: OllamaProvider(baseURL: "http://localhost:11434", model: "llama3.2"),
                                       file: file, store: store, personName: "Andre Leuven")
                await engine.start()
                expect(engine.phase == .asking, "refine interview started (got \(engine.phase))")
                engine.input = "My communication preference changed: I now want detailed briefs that open with an executive summary. Everything else is still accurate."
                await engine.send()
                await engine.generateDraft()
                expect(engine.phase == .drafted, "draft generated")
                let draft = engine.draft
                let (fields, body) = Frontmatter.split(draft)
                let newVersion = SemVer(fields["version"] ?? "")
                let oldVersion = SemVer(originalVersion)
                expect(newVersion != nil && oldVersion != nil && newVersion! > oldVersion!,
                       "version bumped (\(originalVersion) → \(fields["version"] ?? "?"))")
                expect(fields["last_reviewed"] == todayString(), "last_reviewed is today")
                expect(body.contains("## Change Log") || draft.contains("## Change Log"),
                       "Change Log section present")
                expect(engine.target?.suggestedRelativePath == "identity/identity.md",
                       "save path targets the doc's own file")
            }

            print("\n== refine self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Headless repo lint (`--validate`): validate every content file in the cwd
    /// canonical repo against the checklists. Warnings allowed; errors exit 1.
    /// Suitable for CI on the canonical repo.
    static func validateRepo() {
        let cwd = FileManager.default.currentDirectoryPath
        let store = CanonicalStore(rootURL: URL(fileURLWithPath: cwd))
        print("== canonical validation ==")
        print("root: \(cwd)")

        let results = Validator(store: store).validateAll()
        var errorCount = 0
        var warningCount = 0

        if results.isEmpty {
            print("  all content files pass validation")
        }
        for layer in Layer.allCases {
            for file in store.files(layer) where !file.isTemplate {
                guard let findings = results[file.id], !findings.isEmpty else { continue }
                print("\n\(file.layer.rawValue)/\(file.filename):")
                for f in findings {
                    let tag = f.severity == .error ? "error" : "warn "
                    if f.severity == .error { errorCount += 1 } else { warningCount += 1 }
                    print("  [\(tag)] \(f.rule) — \(f.message)")
                }
            }
        }
        // Eval cases (F16) get their own pass — root-level content like validation/.
        for (file, findings) in Validator(store: store).evalFindings().sorted(by: { $0.key < $1.key }) {
            print("\nevals/\(file):")
            for f in findings {
                let tag = f.severity == .error ? "error" : "warn "
                if f.severity == .error { errorCount += 1 } else { warningCount += 1 }
                print("  [\(tag)] \(f.rule) — \(f.message)")
            }
        }
        print("\n== validation: \(errorCount) error(s), \(warningCount) warning(s) ==")
        exit(errorCount == 0 ? 0 : 1)
    }

    /// Fixture-driven validator test (`--validatetest`): builds a scratch repo with a
    /// deliberately broken identity file (copying the cwd repo's templates) and asserts
    /// the expected findings fire — then that a clean example-set validates clean.
    static func validateTest() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fm = FileManager.default
        // Resolve symlinks (/tmp → /private/tmp) so store-relative path lookups match.
        let scratch = URL(fileURLWithPath: "/tmp/validate-fixture-\(ProcessInfo.processInfo.processIdentifier)")
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: scratch) }

        print("== validator fixture self-test ==")
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("  [\(ok ? "ok" : "FAIL")] \(what)")
            if !ok { failures += 1 }
        }

        do {
            // Minimal repo: adapters/ marker + identity template + broken identity.md.
            try fm.createDirectory(at: scratch.appendingPathComponent("adapters"), withIntermediateDirectories: true)
            try fm.createDirectory(at: scratch.appendingPathComponent("identity"), withIntermediateDirectories: true)
            let templateSrc = cwd.appendingPathComponent("identity/identity.template.md")
            try fm.copyItem(at: templateSrc, to: scratch.appendingPathComponent("identity/identity.template.md"))

            // Broken on purpose: bad designation (also violates identity-always-PII),
            // no banner, stale review, non-semver version, invented section, 1 principle,
            // missing several canonical sections, changelog without the version.
            let broken = """
            ---
            title: Broken Identity
            designation: Publicish
            layer: identity
            owner: someone@example.com
            review_cadence: quarterly
            last_reviewed: 2020-01-01
            version: one-point-oh
            status: draft
            target_tools: [openclaw]
            ---

            ## Agent Identity

            - **Name:** X

            ## Operating Principles

            1. Only one rule.

            ## Made Up Section

            surprise

            ## Change Log

            - 2020-01-01 · v9.9.9 — unrelated
            """
            try broken.write(to: scratch.appendingPathComponent("identity/identity.md"),
                             atomically: true, encoding: .utf8)
        } catch {
            print("  [FAIL] fixture setup: \(error.localizedDescription)")
            exit(1)
        }

        let store = CanonicalStore(rootURL: scratch)
        guard let file = store.files(.identity).first(where: { $0.filename == "identity.md" }) else {
            print("  [FAIL] fixture file not loaded (loaded: \(store.files(.identity).map(\.filename)))")
            exit(1)
        }
        let findings = Validator(store: store).validate(file)
        let rules = Set(findings.map(\.rule))
        func has(_ rule: String, _ severity: Finding.Severity) -> Bool {
            findings.contains { $0.rule == rule && $0.severity == severity }
        }

        expect(has("frontmatter.designation", .error), "bad designation flagged (error)")
        expect(has("frontmatter.version", .error), "non-semver version flagged (error)")
        expect(has("banner.presence", .error), "missing banner flagged (error)")
        expect(has("identity.pii", .error), "identity not PII flagged (error)")
        expect(has("sections.missing", .error), "missing canonical sections flagged (error)")
        expect(has("sections.invented", .error), "invented section flagged (error)")
        expect(has("identity.principles_count", .warning), "principles count flagged (warning)")
        expect(has("governance.stale_review", .warning), "stale review flagged (warning)")
        expect(has("changelog.version", .warning), "changelog/version mismatch flagged (warning)")
        expect(!rules.contains("sample.flag"), "no sample rules on a non-example file")

        // Clean sweep: the repo's own example files should have no validation errors
        // (warnings like leakage heuristics are acceptable).
        let exampleStore = CanonicalStore(rootURL: cwd, includeExamples: true)
        let validator = Validator(store: exampleStore)
        var exampleErrorCount = 0
        for layer in Layer.allCases {
            for f in exampleStore.files(layer) where f.isExample {
                let errs = validator.validate(f).filter { $0.severity == .error }
                exampleErrorCount += errs.count
                for e in errs { print("    example error · \(f.filename): \(e.rule) — \(e.message)") }
            }
        }
        expect(exampleErrorCount == 0, "repo example files have no validation errors (got \(exampleErrorCount))")

        print("\n== validator self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
        exit(failures == 0 ? 0 : 1)
    }

    /// Headless verification of the diff/versioning layer (`--difftest`): differ
    /// correctness properties, display folding, bump suggestion/prompt/apply, and
    /// push planning against a scratch directory. Fully deterministic, no network.
    static func diffTest() {
        print("== diff & versioning self-test ==")
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("  [\(ok ? "ok" : "FAIL")] \(what)")
            if !ok { failures += 1 }
        }

        // Differ properties: apply(diff(a,b)) == b across shapes.
        let cases: [(String, String, String)] = [
            ("", "a\nb", "empty → text"),
            ("a\nb", "", "text → empty"),
            ("a\nb\nc", "a\nb\nc", "identical"),
            ("a\nb\nc", "a\nX\nc", "single-line edit"),
            ("s1\ns2\ns3", "s2\ns3\ns1", "reorder"),
        ]
        for (old, new, label) in cases {
            let ops = LineDiff.diff(old: old, new: new)
            expect(LineDiff.apply(ops) == new, "differ reconstructs: \(label)")
        }
        expect(LineDiff.displayRows(LineDiff.diff(old: "same", new: "same")).isEmpty,
               "identical text renders as no-changes")
        let big = (0..<50).map(String.init).joined(separator: "\n")
        let bigEdit = big.replacingOccurrences(of: "25", with: "twenty-five")
        let rows = LineDiff.displayRows(LineDiff.diff(old: big, new: bigEdit))
        expect(rows.contains { if case .fold = $0 { return true }; return false },
               "long unchanged runs fold")

        // Bump suggestion: section change → minor; text tweak → patch.
        let doc = "---\nversion: 1.0.0\n---\n\n## A\n\ntext\n\n## B\n\nmore"
        let textTweak = doc.replacingOccurrences(of: "more", with: "different")
        let sectionChange = doc.replacingOccurrences(of: "## B", with: "## C")
        expect(Versioning.suggestBump(old: doc, new: textTweak) == .patch, "text tweak suggests patch")
        expect(Versioning.suggestBump(old: doc, new: sectionChange) == .minor, "section change suggests minor")

        // Prompt condition: body change with same version → prompt; version bumped → no prompt.
        expect(Versioning.needsBumpPrompt(old: doc, new: textTweak), "unbumped edit needs prompt")
        let bumpedEdit = textTweak.replacingOccurrences(of: "version: 1.0.0", with: "version: 1.0.1")
        expect(!Versioning.needsBumpPrompt(old: doc, new: bumpedEdit), "bumped edit needs no prompt")
        expect(!Versioning.needsBumpPrompt(old: doc, new: doc), "no-op save needs no prompt")

        // applyBump: surgical rewrite + Change Log entry preserving history.
        let withLog = "---\ntitle: T\nversion: 1.0.0\nlast_reviewed: 2020-01-01\n---\n\n## Body\n\nx\n\n## Change Log\n\n- 2020-01-01 · v1.0.0 — initial"
        let bumped = Versioning.applyBump(to: withLog, newVersion: SemVer("1.1.0")!,
                                          today: "2026-07-03", summary: "test edit")
        expect(bumped.contains("version: 1.1.0"), "applyBump rewrites version line")
        expect(bumped.contains("last_reviewed: 2026-07-03"), "applyBump updates last_reviewed")
        expect(bumped.contains("v1.1.0 — test edit") && bumped.contains("v1.0.0 — initial"),
               "applyBump appends entry and preserves history")
        expect(bumped.contains("title: T"), "applyBump leaves other frontmatter untouched")

        // Push planning against a scratch dir.
        let scratch = URL(fileURLWithPath: "/tmp/diff-plan-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var result = BuildResult()
        result.artifacts = [
            BuildArtifact(relativePath: "A.md", contents: "alpha\n", sourceDescription: "t", designation: .pub),
            BuildArtifact(relativePath: "B.md", contents: "beta\n", sourceDescription: "t", designation: .pub),
        ]
        let plan1 = PushPlan.plan(result, into: scratch)
        expect(plan1.new.count == 2 && plan1.changed.isEmpty && plan1.unchanged.isEmpty,
               "first plan: all new (\(plan1.summary))")
        DirectoryPusher.push(result, into: scratch, backup: false)
        let plan2 = PushPlan.plan(result, into: scratch)
        expect(plan2.unchanged.count == 2 && plan2.toWrite.isEmpty,
               "second plan: all unchanged (\(plan2.summary))")
        result.artifacts[0] = BuildArtifact(relativePath: "A.md", contents: "alpha2\n",
                                            sourceDescription: "t", designation: .pub)
        let plan3 = PushPlan.plan(result, into: scratch)
        expect(plan3.changed.count == 1 && plan3.unchanged.count == 1,
               "third plan: 1 changed 1 unchanged (\(plan3.summary))")

        // Provenance-version extraction (staleness warning input).
        let deployed = "<!-- owner: x | version: 2.3.4 | reviewed: 2026-01-01 | designation: PII -->\nbody"
        expect(AppState.provenanceVersion(in: deployed) == "2.3.4", "provenance version extracted")

        print("\n== diff self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
        exit(failures == 0 ? 0 : 1)
    }

    /// Headless verification of the git layer (`--gittest`): porcelain parsing units +
    /// a full status → commit → history → show cycle against a scratch git repo, plus
    /// the no-repo degradation path. Local git only — an audit assertion confirms the
    /// service source contains no remote-touching subcommands.
    static func gitTest() {
        Task { @MainActor in
            print("== git integration self-test ==")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            // Porcelain parsing units.
            let porcelain = """
             M identity/identity.md
            ?? memory/new-entry.md
            R  old.md -> context/renamed.md
             M "dir with space/file.md"
            """
            let parsed = GitService.parsePorcelain(porcelain)
            expect(parsed.contains("identity/identity.md"), "porcelain: modified path parsed")
            expect(parsed.contains("memory/new-entry.md"), "porcelain: untracked path parsed")
            expect(parsed.contains("context/renamed.md") && !parsed.contains("old.md"),
                   "porcelain: rename keeps the new path")
            expect(parsed.contains("dir with space/file.md"), "porcelain: quoted path unquoted")

            // Scratch repo lifecycle.
            let fm = FileManager.default
            let scratch = URL(fileURLWithPath: "/tmp/gittest-\(ProcessInfo.processInfo.processIdentifier)")
                .resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: scratch) }
            try? fm.createDirectory(at: scratch.appendingPathComponent("identity"), withIntermediateDirectories: true)
            _ = await OpenClawService.run("/usr/bin/git", ["-C", scratch.path, "init", "-q"])
            _ = await OpenClawService.run("/usr/bin/git", ["-C", scratch.path, "config", "user.name", "SelfTest"])
            _ = await OpenClawService.run("/usr/bin/git", ["-C", scratch.path, "config", "user.email", "selftest@example.com"])
            try? "v1 content\n".write(to: scratch.appendingPathComponent("identity/identity.md"),
                                      atomically: true, encoding: .utf8)

            let git = GitService(root: scratch)
            await git.refresh()
            expect(git.isRepo, "scratch repo detected")
            expect(git.dirtyPaths.contains("identity/identity.md"), "new file shows dirty")
            expect(!git.hasRemote, "no remote on scratch repo")

            let log1 = await git.commit(paths: ["identity/identity.md"], message: "initial identity")
            expect(log1.contains { $0.hasPrefix("✓ committed") }, "commit succeeds (\(log1.last ?? ""))")
            expect(git.dirtyPaths.isEmpty, "working tree clean after commit")

            try? "v2 content\n".write(to: scratch.appendingPathComponent("identity/identity.md"),
                                      atomically: true, encoding: .utf8)
            await git.refresh()
            expect(git.dirtyPaths.contains("identity/identity.md"), "edit shows dirty again")
            _ = await git.commit(paths: ["identity/identity.md"], message: "second version")

            let history = await git.history(path: "identity/identity.md")
            expect(history.count == 2, "history lists 2 commits (got \(history.count))")
            expect(history.first?.subject == "second version", "history newest-first")
            if history.count == 2 {
                let old = await git.show(commit: history[1].id, path: "identity/identity.md")
                expect(old == "v1 content\n", "show returns the old version verbatim")
            }

            // Ignore detection (PII posture): a .gitignore that excludes filled-in files
            // but re-allows templates → the filled-in file reads as ignored, template not.
            try? """
            identity/*
            !identity/*.template.md
            """.write(to: scratch.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try? "template\n".write(to: scratch.appendingPathComponent("identity/identity.template.md"),
                                    atomically: true, encoding: .utf8)
            await git.refresh()
            // A fresh, untracked filled-in file (identity/identity.md is already tracked
            // above, and git never reports tracked files as ignored — which is exactly why
            // agent_os's untracked PII files DO read as ignored).
            let ignored = await git.ignoredPaths(["identity/role.md", "identity/identity.template.md"])
            expect(ignored == ["identity/role.md"],
                   "check-ignore flags the untracked filled-in file, not the template (got \(ignored))")
            expect(await git.ignoredPaths([]).isEmpty, "ignoredPaths empty for empty input")

            // Commit with a stale list that includes a now-ignored path: the ignored
            // file is skipped (logged), the rest commits — never a hard failure.
            try? "pii\n".write(to: scratch.appendingPathComponent("identity/role.md"),
                               atomically: true, encoding: .utf8)
            let mixedLog = await git.commit(
                paths: ["identity/role.md", "identity/identity.template.md", ".gitignore"],
                message: "mixed stage")
            expect(mixedLog.contains { $0.contains("skipped 1 gitignored") },
                   "commit logs the skipped ignored file")
            expect(mixedLog.contains { $0.hasPrefix("✓ committed") },
                   "commit still succeeds for the stageable files (\(mixedLog.last ?? ""))")
            // All-ignored selection degrades to a clear message, not a git error.
            let allIgnored = await git.commit(paths: ["identity/role.md"], message: "nope")
            expect(allIgnored.contains { $0.contains("all selected files are gitignored") },
                   "all-ignored selection explains itself")

            // No-repo degradation.
            let plain = URL(fileURLWithPath: "/tmp/gittest-plain-\(ProcessInfo.processInfo.processIdentifier)")
            try? fm.createDirectory(at: plain, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: plain) }
            let noRepo = GitService(root: plain)
            await noRepo.refresh()
            expect(!noRepo.isRepo && noRepo.dirtyPaths.isEmpty, "non-repo root degrades cleanly")
            let noHistory = await noRepo.history(path: "x.md")
            expect(noHistory.isEmpty, "history empty outside a repo")

            print("\n== git self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Headless verification of scaffolding (`--scaffoldtest`): create a fresh canonical
    /// repo from the embedded templates and from a copy-source, assert validity,
    /// interview-target availability, git init, and the non-empty-dir refusal.
    static func scaffoldTest() {
        Task { @MainActor in
            print("== scaffold self-test ==")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            let fm = FileManager.default
            let pid = ProcessInfo.processInfo.processIdentifier

            // Embedded-template scaffold (fresh machine path).
            let fresh = URL(fileURLWithPath: "/tmp/scaffold-fresh-\(pid)").resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: fresh) }
            do {
                let log = try Scaffold.create(at: fresh, copyingTemplatesFrom: nil)
                log.forEach { print("  \($0)") }
                print("  \(await Scaffold.gitInit(at: fresh))")
            } catch {
                expect(false, "embedded scaffold threw: \(error.localizedDescription)")
            }
            let freshStore = CanonicalStore(rootURL: fresh)
            expect(freshStore.isValidRoot, "scaffolded repo passes isValidRoot")
            expect(freshStore.contentCount == 0, "no content files (fresh install — no samples)")
            let targets = InterviewTarget.all(in: freshStore)
            expect(targets.count >= 5, "interview finds ≥ 5 trainable targets (got \(targets.count))")
            expect(BootstrapEngine.resolveSteps(in: freshStore).count == 5,
                   "bootstrap wizard resolves all 5 steps")
            let gitDir = fresh.appendingPathComponent(".git")
            expect(fm.fileExists(atPath: gitDir.path), "git initialized")
            let ignore = (try? String(contentsOf: fresh.appendingPathComponent(".gitignore"), encoding: .utf8)) ?? ""
            expect(ignore.contains("bak-studio"), ".gitignore covers Studio backups")

            // Embedded templates must pass the validator's template parsing (they feed
            // section rules for authored content).
            for (path, _) in Scaffold.embeddedTemplates {
                let name = (path as NSString).lastPathComponent
                let layerName = (path as NSString).pathComponents.first ?? ""
                let layer = Layer(rawValue: layerName)
                let loaded = layer.flatMap { l in freshStore.files(l).first { $0.filename == name } }
                expect(loaded?.isTemplate == true, "template loaded as template: \(path)")
            }

            // Copy-source scaffold (from the cwd repo).
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let copied = URL(fileURLWithPath: "/tmp/scaffold-copy-\(pid)").resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: copied) }
            do {
                _ = try Scaffold.create(at: copied, copyingTemplatesFrom: cwd)
            } catch {
                expect(false, "copy scaffold threw: \(error.localizedDescription)")
            }
            let copiedStore = CanonicalStore(rootURL: copied)
            expect(copiedStore.isValidRoot, "copy-scaffolded repo passes isValidRoot")
            expect(InterviewTarget.all(in: copiedStore).count == InterviewTarget.all(in: CanonicalStore(rootURL: cwd)).count,
                   "copied templates yield the same interview targets as the source repo")

            // Refusal on non-empty target.
            do {
                _ = try Scaffold.create(at: cwd, copyingTemplatesFrom: nil)
                expect(false, "scaffold over a non-empty dir must throw")
            } catch {
                expect(true, "scaffold refuses non-empty directory")
            }

            print("\n== scaffold self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Headless verification of the connections manager (`--connectionstest`): doc
    /// parsing against the repo's examples, registration surfaces + write/backup/
    /// restore against scratch configs, secret refusal, and corrupt-config diagnosis.
    /// Never touches the live openclaw.json.
    static func connectionsTest() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        print("== connections manager self-test ==")
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            print("  [\(ok ? "ok" : "FAIL")] \(what)")
            if !ok { failures += 1 }
        }

        // Doc parsing from the repo's fictional examples.
        let store = CanonicalStore(rootURL: cwd, includeExamples: true)
        let docs = store.files(.connections).filter { !$0.isTemplate }
            .map { ConnectionDoc.parse($0, store: store) }
        expect(docs.count >= 3, "parsed \(docs.count) example connection docs")
        let calendar = docs.first { $0.name == "calendar-read" }
        expect(calendar?.isMCP == true, "calendar-read is mcp")
        expect(calendar?.proposedEntry != nil, "calendar-read has an mcpServers entry in its Configuration JSON")
        expect(calendar?.literalSecretFinding() == nil, "env-var reference passes the secret scan")
        expect(calendar?.isReadOnly == true, "calendar-read access mode read-only")
        let cli = docs.first { $0.mechanism == "cli" }
        expect(cli != nil && cli?.isMCP == false, "cli connection recognized as non-mcp")

        // Secret scan unit: literal token refused; env ref allowed.
        expect(ConnectionDoc.scanForSecrets(["env": ["TOKEN": "sk-abcdef1234567890abcd"]]) != nil,
               "literal sk- token detected")
        expect(ConnectionDoc.scanForSecrets(["env": ["TOKEN": "$MY_TOKEN"]]) == nil,
               "$ENV reference allowed")

        // Scratch config with a recognized surface → writable, write/backup/verify.
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: "/tmp/conn-test-\(ProcessInfo.processInfo.processIdentifier)")
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: scratch) }
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try? #"{"tools": {"profile": "minimal"}, "mcpServers": {}}"#
            .write(to: scratch.appendingPathComponent("openclaw.json"), atomically: true, encoding: .utf8)

        var config = OpenClawConfig.load(stateDir: scratch)
        expect(config.surface == .topLevelMCPServers, "recognized mcpServers surface")
        if let calendar {
            let proposal = config.propose(calendar)
            guard case .writable(let newText, let snippet) = proposal else {
                expect(false, "proposal is writable (got \(proposal))")
                print("\n== connections self-test FAILED ==")
                exit(1)
            }
            expect(snippet.contains("calendar-read"), "snippet names the server")
            let log = config.write(newConfigText: newText)
            log.forEach { print("  \($0)") }
            expect(fm.fileExists(atPath: scratch.appendingPathComponent("openclaw.json.bak-studio").path),
                   "backup created")
            config = OpenClawConfig.load(stateDir: scratch)
            expect(config.registeredNames.contains("calendar-read"), "registered after write")
            if case .alreadyRegistered = config.propose(calendar) {
                expect(true, "duplicate registration refused")
            } else {
                expect(false, "duplicate registration refused")
            }
        }

        // No recognized surface → manual-only with guidance.
        try? #"{"tools": {"profile": "minimal"}, "gateway": {}}"#
            .write(to: scratch.appendingPathComponent("openclaw.json"), atomically: true, encoding: .utf8)
        let bare = OpenClawConfig.load(stateDir: scratch)
        expect(bare.surface == .none, "real-gateway shape has no recognized surface")
        if let calendar {
            if case .manualOnly(let snippet, _) = bare.propose(calendar) {
                expect(snippet.contains("calendar-read"), "manual-only offers a copyable entry")
            } else {
                expect(false, "manual-only offers a copyable entry")
            }
        }

        // Secret refusal end-to-end: doc entry with a literal key.
        let secretDoc = ConnectionDoc(
            id: "x", file: store.files(.connections).first!, name: "leaky",
            mechanism: "mcp", accessMode: "read-only", capabilities: ["x"],
            configurationBlock: "", securityNotes: "", warnings: [],
            proposedEntry: ["env": ["KEY": "ghp_0123456789abcdef012345"]])
        if case .refusedSecret = bare.propose(secretDoc) {
            expect(true, "literal secret refused at proposal time")
        } else {
            expect(false, "literal secret refused at proposal time")
        }

        // Corrupt config → diagnosis only.
        try? "{ not json".write(to: scratch.appendingPathComponent("openclaw.json"), atomically: true, encoding: .utf8)
        let corrupt = OpenClawConfig.load(stateDir: scratch)
        if case .unparseable = corrupt.state {
            expect(true, "corrupt config diagnosed")
        } else {
            expect(false, "corrupt config diagnosed")
        }

        print("\n== connections self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
        exit(failures == 0 ? 0 : 1)
    }

    /// Scripted provider for deterministic streaming tests (delays, mid-stream failure).
    private struct FakeStreamProvider: LLMProvider {
        let deltas: [String]
        let delayMs: UInt64
        var failAfter: Int? = nil
        var flakyCounter: Counter? = nil   // fails while counter == 0, then succeeds

        final class Counter: @unchecked Sendable { var n = 0 }

        func complete(system: String, messages: [ChatMessage]) async throws -> String { deltas.joined() }
        func listModels() async throws -> [String] { [] }

        func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    if let flaky = flakyCounter {
                        if flaky.n == 0 {
                            flaky.n += 1
                            continuation.finish(throwing: LLMError.network("flaky first attempt"))
                            return
                        }
                    }
                    for (i, delta) in deltas.enumerated() {
                        if let f = failAfter, i >= f {
                            continuation.finish(throwing: LLMError.network("mid-stream failure"))
                            return
                        }
                        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                        if Task.isCancelled { continuation.finish(); return }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Headless suite run (`--eval [harness]`, default openclaw): loads evals/ from
    /// the cwd canonical repo, builds the harness's artifacts, runs subject + judge
    /// with the configured provider, records history, and exits non-zero on any fail.
    /// CI-ready; requires a reachable provider (local Ollama works offline).
    static func evalRun() {
        Task { @MainActor in
            let cwd = FileManager.default.currentDirectoryPath
            let root = URL(fileURLWithPath: cwd)
            let args = CommandLine.arguments
            let harness = args.firstIndex(of: "--eval")
                .flatMap { i in args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil }
                ?? "openclaw"
            let adapters: [String: HarnessAdapter] = [
                "openclaw": OpenClawAdapter(), "hermes": HermesAdapter(),
                "claude-cowork": CoworkAdapter(), "codex": CodexAdapter(),
            ]
            guard let adapter = adapters[harness] else {
                print("✗ unknown harness \"\(harness)\" — one of \(adapters.keys.sorted())")
                exit(2)
            }
            print("== eval run · \(harness) ==")
            print("canonical root: \(cwd)")

            let store = CanonicalStore(rootURL: root)
            let all = EvalCase.loadAll(root: root)
            let cases = all.filter { c in
                store.file(atRelativePath: c.source).map(\.include) ?? false
            }
            guard !cases.isEmpty else {
                print("✗ no runnable eval cases in evals/ (found \(all.count) total)")
                exit(2)
            }
            let result = adapter.build(from: store)
            let context = EvalRunner.primedContext(harnessID: harness, harnessName: harness,
                                                   result: result)
            let provider = LLMSettings().makeProvider()

            var records: [EvalStore.CaseResult] = []
            var failures = 0
            for evalCase in cases {
                do {
                    let transcript = try await EvalRunner.runSubject(
                        case: evalCase, context: context, provider: provider)
                    let verdict = await EvalJudge.score(case: evalCase, transcript: transcript,
                                                        provider: provider)
                    if verdict.kind == .fail { failures += 1 }
                    print("  [\(verdict.kind.rawValue)\(verdict.deterministic ? "·det" : "")] \(evalCase.name) — \(verdict.reason)")
                    records.append(EvalStore.CaseResult(name: evalCase.name,
                                                        verdict: verdict.kind.rawValue,
                                                        reason: verdict.reason,
                                                        source: evalCase.source))
                } catch {
                    failures += 1
                    print("  [fail] \(evalCase.name) — subject error: \(error.localizedDescription)")
                    records.append(EvalStore.CaseResult(name: evalCase.name, verdict: "fail",
                                                        reason: "subject error", source: evalCase.source))
                }
            }
            EvalStore.standard.append(EvalStore.RunRecord(
                date: Date(), harness: harness, results: records,
                sourceVersions: context.sourceVersions))
            let passed = records.filter { $0.verdict == "pass" }.count
            print("\n== eval run \(failures == 0 ? "passed" : "FAILED") — \(passed)/\(records.count) ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Enterprise-loop verification (`--enterprisetest`): repo initialize/validity,
    /// candidate discovery rules (Enterprise/Public in, PII out, already-contributed
    /// out, skipped out), contribute provenance stamping, admin allow/disallow moves,
    /// pull with the validation gate, and vet parsing. Deterministic; no network.
    static func enterpriseTest() {
        Task { @MainActor in
            print("== enterprise self-test ==")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            let fm = FileManager.default
            let pid = ProcessInfo.processInfo.processIdentifier
            let base = URL(fileURLWithPath: "/tmp/enterprisetest-\(pid)").resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: base) }
            let repoRoot = base.appendingPathComponent("enterprise")
            let canonical = base.appendingPathComponent("canonical")
            try? Scaffold.create(at: canonical, copyingTemplatesFrom: nil)

            // Initialize + validity.
            try? EnterpriseRepo.initialize(at: repoRoot)
            let repo = EnterpriseRepo(root: repoRoot)
            expect(repo.isValid, "initialized repo is valid (suggested/ + catalog/)")
            expect(fm.fileExists(atPath: repoRoot.appendingPathComponent("README.md").path),
                   "README written on initialize")

            // Seed canonical: one Enterprise skill (candidate), one PII skill (never).
            let entSkill = """
            ---
            title: Weekly Status Rollup
            designation: Enterprise
            layer: skills
            name: weekly-status-rollup
            scope: personal
            owner: t@example.com
            review_cadence: quarterly
            last_reviewed: 2026-07-11
            version: 1.0.0
            status: active
            target_tools: [openclaw]
            ---

            > **Classification: Enterprise** — test.

            ## Trigger

            Friday afternoon.
            """
            try? entSkill.write(to: canonical.appendingPathComponent("skills/weekly-status-rollup.md"),
                                atomically: true, encoding: .utf8)
            try? entSkill.replacingOccurrences(of: "designation: Enterprise", with: "designation: PII")
                .replacingOccurrences(of: "name: weekly-status-rollup", with: "name: private-skill")
                .replacingOccurrences(of: "title: Weekly Status Rollup", with: "title: Private Skill")
                .write(to: canonical.appendingPathComponent("skills/private-skill.md"),
                       atomically: true, encoding: .utf8)
            let store = CanonicalStore(rootURL: canonical)

            func discoverCandidates() -> [CanonicalFile] {
                var found: [CanonicalFile] = []
                let skipped = EnterpriseRepo.skippedHashes()
                for layer in EnterpriseRepo.sharedLayers {
                    for file in store.files(layer)
                    where !file.isTemplate && !file.isExample
                        && (file.designation == .enterprise || file.designation == .pub) {
                        let contents = store.read(file)
                        guard !skipped.contains(PushLedger.sha256(contents)) else { continue }
                        let name = Frontmatter.split(contents).0["name"]
                            ?? (file.filename as NSString).deletingPathExtension
                        guard repo.stage(ofName: name, layer: layer) == nil else { continue }
                        found.append(file)
                    }
                }
                return found
            }

            var cands = discoverCandidates()
            expect(cands.count == 1 && cands.first?.filename == "weekly-status-rollup.md",
                   "discovery: Enterprise in, PII out (got \(cands.map(\.filename)))")

            // Contribute → suggested/ with provenance.
            _ = try? repo.contribute(contents: entSkill, layer: .skills,
                                     filename: "weekly-status-rollup.md",
                                     contributedBy: "t@example.com", today: "2026-07-11")
            let suggested = repo.items(in: .suggested)
            expect(suggested.count == 1, "contribution lands in suggested/")
            expect(suggested.first?.contributedBy == "t@example.com"
                   && suggested.first?.contributedOn == "2026-07-11",
                   "provenance frontmatter stamped")
            cands = discoverCandidates()
            expect(cands.isEmpty, "already-contributed item leaves the candidate list")

            // Admin: allow moves to catalog/.
            if let item = suggested.first {
                _ = try? repo.allow(item)
            }
            expect(repo.items(in: .suggested).isEmpty && repo.items(in: .catalog).count == 1,
                   "allow moves suggested → catalog")

            // Admin: disallow moves with a required note.
            _ = try? repo.contribute(contents: entSkill.replacingOccurrences(
                                        of: "name: weekly-status-rollup", with: "name: risky-skill")
                                        .replacingOccurrences(of: "title: Weekly Status Rollup",
                                                              with: "title: Risky Skill"),
                                     layer: .skills, filename: "risky-skill.md",
                                     contributedBy: "t@example.com", today: "2026-07-11")
            if let pending = repo.items(in: .suggested).first {
                _ = try? repo.disallow(pending, note: "violates acceptable-use policy")
            }
            let disallowed = repo.items(in: .disallowed)
            expect(disallowed.count == 1 && disallowed.first?.moderationNote.contains("acceptable-use") == true,
                   "disallow moves with the moderation note")
            expect(repo.items(in: .catalog).count == 1, "disallowed item never reaches the catalog")

            // Pull: validation gate + write into a second canonical repo.
            let canonical2 = base.appendingPathComponent("canonical2")
            try? Scaffold.create(at: canonical2, copyingTemplatesFrom: nil)
            let store2 = CanonicalStore(rootURL: canonical2)
            if let item = repo.items(in: .catalog).first {
                let target = "\(item.layer.rawValue)/\(item.filename)"
                let errors = ProposalEngine.validationErrors(contents: item.contents,
                                                             target: target, store: store2)
                // The seeded skill is intentionally minimal — assert the gate RUNS and
                // reports missing sections rather than silently passing garbage.
                expect(errors.contains { $0.rule == "sections.missing" },
                       "pull gate catches an incomplete document")
                // A complete document passes and lands.
                let full = """
                ---
                title: Weekly Status Rollup
                designation: Enterprise
                layer: skills
                name: weekly-status-rollup
                scope: personal
                owner: t@example.com
                review_cadence: quarterly
                last_reviewed: 2026-07-11
                version: 1.0.0
                status: active
                target_tools: [openclaw]
                contributed_by: t@example.com
                contributed_on: 2026-07-11
                ---

                > **Classification: Enterprise** — test.

                ## Classification

                Enterprise — reusable procedure.

                ## Trigger

                Friday afternoon.

                ## Inputs

                - Updates.

                ## Procedure

                1. Group by workstream.

                ## Output

                A rollup.

                ## Examples

                Example rollup.

                ## Test Plan

                - Groups by workstream.

                ## Evolution Notes

                - None.

                ## Change Log

                - 2026-07-11 · v1.0.0 — created
                """
                let cleanErrors = ProposalEngine.validationErrors(contents: full,
                                                                  target: target, store: store2)
                expect(cleanErrors.isEmpty, "complete document passes the pull gate (got \(cleanErrors.map(\.rule)))")
                _ = try? store2.createFile(relativePath: target, contents: full)
                store2.reload()
                expect(store2.file(atRelativePath: target) != nil, "pulled document lands in canonical")
            } else { expect(false, "catalog item available to pull") }

            // Skip memory. NOTE: restored explicitly below — a `defer` never runs
            // past exit(), which is how the first version leaked a skip hash into
            // real defaults and broke subsequent runs.
            let savedSkips = UserDefaults.standard.stringArray(forKey: EnterpriseRepo.skippedKey)
            let extra = """
            ---
            title: Another Enterprise Skill
            designation: Enterprise
            layer: skills
            name: another-skill
            scope: personal
            owner: t@example.com
            review_cadence: quarterly
            last_reviewed: 2026-07-11
            version: 0.1.0
            status: draft
            target_tools: [openclaw]
            ---

            > **Classification: Enterprise** — test.

            ## Trigger

            x
            """
            try? extra.write(to: canonical.appendingPathComponent("skills/another-skill.md"),
                             atomically: true, encoding: .utf8)
            store.reload()
            expect(discoverCandidates().count == 1, "new enterprise doc becomes a candidate")
            EnterpriseRepo.recordSkip(hash: PushLedger.sha256(extra))
            expect(discoverCandidates().isEmpty, "skip is remembered by content hash")
            // Restore the real skip list BEFORE exit (defer would never run).
            UserDefaults.standard.set(savedSkips, forKey: EnterpriseRepo.skippedKey)

            // Vet parsing: strict, never fails open.
            expect(EnterpriseVet.parse("VERDICT: share\nSUMMARY: a rollup skill\nCONCERNS: none")
                   == EnterpriseVet.Result(share: true, summary: "a rollup skill", concerns: "none"),
                   "vet parses a share verdict")
            expect(EnterpriseVet.parse("VERDICT: hold\nSUMMARY: \nCONCERNS: contains a home address")?.share == false,
                   "vet parses a hold verdict")
            expect(EnterpriseVet.parse("sounds fine to me!") == nil,
                   "unparseable vet output is rejected (never fails open)")

            print("\n== enterprise self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Demo-mode content verification (`--demotest`): the Orbit Labs OS installs,
    /// validates with ZERO errors, populates every layer, builds OpenClaw artifacts,
    /// exposes interview targets and eval cases, and reinstalls deterministically.
    static func demoTest() {
        Task { @MainActor in
            print("== demo-mode self-test ==")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            let fm = FileManager.default
            let pid = ProcessInfo.processInfo.processIdentifier
            let root = URL(fileURLWithPath: "/tmp/demotest-\(pid)").resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: root) }

            do { _ = try DemoContent.install(at: root, today: "2026-07-11") } catch {
                expect(false, "install threw: \(error.localizedDescription)")
                print("\n== demo self-test FAILED ==")
                exit(1)
            }

            let store = CanonicalStore(rootURL: root)
            expect(store.isValidRoot, "demo repo is a valid Agent OS root")
            for layer in Layer.allCases {
                let content = store.files(layer).filter { !$0.isTemplate && !$0.isExample }
                expect(!content.isEmpty, "\(layer.rawValue) has demo content (\(content.count) file(s))")
            }

            // The whole point: the demo content is exemplary — zero validation errors.
            let validator = Validator(store: store)
            let errors = validator.validateAll().values.flatMap { $0 }.filter { $0.severity == .error }
            expect(errors.isEmpty, "demo content validates with 0 errors (got \(errors.count): \(errors.prefix(3).map(\.rule)))")
            let evalErrors = validator.evalFindings().values.flatMap { $0 }.filter { $0.severity == .error }
            expect(evalErrors.isEmpty, "demo eval cases validate with 0 errors")

            // Compiles: the OpenClaw adapter produces a full artifact set.
            let result = OpenClawAdapter().build(from: store)
            expect(result.artifacts.contains { $0.relativePath == "SOUL.md" }, "build produces SOUL.md")
            expect(result.artifacts.contains { $0.relativePath.hasPrefix("skills/") }, "build produces skills")
            expect(result.artifacts.contains { $0.relativePath.hasPrefix("memory/") || $0.relativePath == "MEMORY.md" },
                   "build produces memory artifacts")
            expect(result.artifacts.first { $0.relativePath == "SOUL.md" }?.contents.contains("Beacon") == true,
                   "SOUL.md carries the demo agent")

            // Authoring + evals surfaces have material.
            expect(!InterviewTarget.all(in: store).isEmpty, "interview targets available")
            let cases = EvalCase.loadAll(root: root)
            expect(cases.count >= 2, "≥2 eval cases load (got \(cases.count))")
            expect(cases.allSatisfy { store.file(atRelativePath: $0.source) != nil },
                   "every eval case's source resolves")

            // Deterministic reinstall: dirty the repo, reinstall, content is back.
            try? "vandalized".write(to: root.appendingPathComponent("identity/identity.md"),
                                    atomically: true, encoding: .utf8)
            _ = try? DemoContent.install(at: root, today: "2026-07-11")
            let restored = (try? String(contentsOf: root.appendingPathComponent("identity/identity.md"),
                                        encoding: .utf8)) ?? ""
            expect(restored.contains("Beacon"), "reinstall resets edits (deterministic demos)")

            print("\n== demo self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Deterministic eval-layer verification (`--evaltest`): case parse/render
    /// roundtrip, the validator's evals ruleset, deterministic draft generation,
    /// LLM-draft disposal, assertion short-circuits, judge parsing, store history +
    /// regression deltas, and the refine-seed handoff. Scripted providers; no network.
    static func evalTest() {
        Task { @MainActor in
            print("== eval self-test ==")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            let fm = FileManager.default
            let pid = ProcessInfo.processInfo.processIdentifier
            let base = URL(fileURLWithPath: "/tmp/evaltest-\(pid)").resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: base) }
            let repo = base.appendingPathComponent("repo")
            try? Scaffold.create(at: repo, copyingTemplatesFrom: nil)

            // Render → parse roundtrip.
            let rendered = EvalCase.render(
                title: "Recall pool routine", name: "recall-pool", designation: "PII",
                source: "memory/pool.md", sourceVersion: "0.1.0",
                owner: "t@example.com", today: "2026-07-11",
                prompt: "What seasonal chores do I have?",
                expectation: "Mentions opening the pool in spring and closing in fall.",
                mustContain: ["spring", "fall"], mustNotContain: ["winterize the boat"])
            let parsed = EvalCase.parse(filename: "recall-pool.md", text: rendered)
            expect(parsed != nil, "rendered case parses")
            expect(parsed?.mustContain == ["spring", "fall"], "Must Contain items roundtrip")
            expect(parsed?.mustNotContain == ["winterize the boat"], "Must Not Contain items roundtrip")
            expect(parsed?.source == "memory/pool.md", "source roundtrips")
            expect(EvalCase.parse(filename: "x.md", text: "---\nname: x\nsource: y\n---\n\n## Expectation\n\nz") == nil,
                   "case without a Prompt is rejected")

            // Validator evals ruleset against a scratch repo.
            let memorySeed = """
            ---
            title: Pool
            designation: PII
            layer: memory
            entry_type: user
            name: pool
            description: pool chores
            owner: t@example.com
            review_cadence: monthly
            last_reviewed: 2026-07-11
            version: 0.1.0
            status: draft
            target_tools: [openclaw]
            ---

            > **Classification: PII** — test.

            ## Entry

            Opens the pool every spring; closes it every fall.
            """
            try? memorySeed.write(to: repo.appendingPathComponent("memory/pool.md"),
                                  atomically: true, encoding: .utf8)
            let evalsDir = repo.appendingPathComponent(EvalCase.dirName)
            try? fm.createDirectory(at: evalsDir, withIntermediateDirectories: true)
            try? rendered.write(to: evalsDir.appendingPathComponent("recall-pool.md"),
                                atomically: true, encoding: .utf8)
            try? "---\nname: Bad Name\ndesignation: Secret\nsource: memory/nope.md\n---\n\nno sections"
                .write(to: evalsDir.appendingPathComponent("broken.md"),
                       atomically: true, encoding: .utf8)
            let store = CanonicalStore(rootURL: repo)
            let evalFindings = Validator(store: store).evalFindings()
            expect(evalFindings["recall-pool.md"] == nil, "well-formed case validates clean")
            let brokenRules = Set((evalFindings["broken.md"] ?? []).map(\.rule))
            expect(brokenRules.contains("evals.name") && brokenRules.contains("evals.source")
                   && brokenRules.contains("evals.prompt") && brokenRules.contains("evals.expectation"),
                   "malformed case flags name/source/prompt/expectation (got \(brokenRules))")

            // Deterministic drafts from a skill Test Plan + memory entry.
            let skill = """
            ---
            title: Prep QBR Deck
            designation: Enterprise
            layer: skills
            name: prep-qbr-deck
            owner: t@example.com
            review_cadence: quarterly
            last_reviewed: 2026-07-11
            version: 0.2.0
            status: active
            target_tools: [openclaw]
            ---

            > **Classification: Enterprise** — test.

            ## Trigger

            The user asks to prepare the quarterly business review.

            ## Test Plan

            - Deck outline covers revenue, risks, and asks.
            """
            try? skill.write(to: repo.appendingPathComponent("skills/prep-qbr-deck.md"),
                             atomically: true, encoding: .utf8)
            let store2 = CanonicalStore(rootURL: repo)
            let drafts = EvalGenerator.deterministicDrafts(store: store2,
                                                           ownerEmail: "t@example.com",
                                                           today: "2026-07-11")
            expect(drafts.contains { $0.filename == "skill-prep-qbr-deck.md" },
                   "skill Test Plan yields a case skeleton")
            expect(drafts.contains { $0.filename == "recall-pool.md" },
                   "memory entry yields a recall probe")
            expect(drafts.allSatisfy { EvalCase.parse(filename: $0.filename, text: $0.contents) != nil },
                   "all deterministic drafts parse as valid cases")
            expect(drafts.first { $0.filename == "recall-pool.md" }?.exists == true,
                   "existing case file is flagged for overwrite review")

            // LLM identity-draft disposal: one valid block kept, garbage dropped.
            let validBlock = EvalCase.render(
                title: "Tone stays terse", name: "identity-terse-tone", designation: "PII",
                source: "identity/identity.md", sourceVersion: "0.1.0",
                owner: "t@example.com", today: "2026-07-11",
                prompt: "Give me a status update on the migration.",
                expectation: "Reply is terse bullets, no preamble.")
            let identityDrafts = EvalGenerator.parseIdentityDrafts(
                validBlock + "\n=====\n" + "just some prose, not a case", root: repo)
            expect(identityDrafts.count == 1 && identityDrafts.first?.filename == "identity-terse-tone.md",
                   "identity drafting keeps the valid block, drops garbage")

            // Judge: deterministic assertions short-circuit (a throwing provider proves
            // no model call happens), judge parsing, and the full score pipeline.
            struct ExplodingProvider: LLMProvider {
                struct Boom: Error {}
                func complete(system: String, messages: [ChatMessage]) async throws -> String { throw Boom() }
                func listModels() async throws -> [String] { [] }
            }
            let poolCase = parsed!
            let banned = await EvalJudge.score(
                case: poolCase, transcript: "You should winterize the boat in fall and spring.",
                provider: ExplodingProvider())
            expect(banned.kind == .fail && banned.deterministic,
                   "Must-Not-Contain fails deterministically without a judge call")
            let missing = await EvalJudge.score(
                case: poolCase, transcript: "You open the pool in spring.",
                provider: ExplodingProvider())
            expect(missing.kind == .fail && missing.deterministic,
                   "Must-Contain miss fails deterministically")
            struct ScriptedJudge: LLMProvider {
                let reply: String
                func complete(system: String, messages: [ChatMessage]) async throws -> String { reply }
                func listModels() async throws -> [String] { [] }
            }
            let judged = await EvalJudge.score(
                case: poolCase, transcript: "Open the pool in spring, close it in fall.",
                provider: ScriptedJudge(reply: "VERDICT: pass\nREASON: matches the routine"))
            expect(judged.kind == .pass && !judged.deterministic && judged.reason.contains("routine"),
                   "assertions pass → judge grades the expectation")
            expect(EvalJudge.parseVerdict("nonsense") == nil, "garbage judge output is unparseable")
            let assertOnly = EvalCase(filename: "a.md", name: "a", title: "a",
                                      source: "memory/pool.md", sourceVersion: "",
                                      prompt: "p", expectation: "",
                                      mustContain: ["spring"], mustNotContain: [])
            let autoPass = await EvalJudge.score(case: assertOnly, transcript: "spring!",
                                                 provider: ExplodingProvider())
            expect(autoPass.kind == .pass && autoPass.deterministic,
                   "assertion-only case passes deterministically")

            // Subject context carries the artifacts + provenance versions.
            var build = BuildResult()
            build.artifacts = [BuildArtifact(
                relativePath: "SOUL.md",
                contents: "<!-- owner: t@example.com | version: 0.9.0 | reviewed: 2026-07-11 | designation: PII -->\nBe terse.",
                sourceDescription: "Identity ← identity.md", designation: .pii)]
            let context = EvalRunner.primedContext(harnessID: "openclaw",
                                                   harnessName: "OpenClaw", result: build)
            expect(context.systemPrompt.contains("Be terse.") && context.systemPrompt.contains("SOUL.md"),
                   "primed context embeds the artifacts")
            expect(context.sourceVersions["SOUL.md"] == "0.9.0",
                   "provenance versions captured for history")

            // Store: history + regression delta.
            let evalStore = EvalStore(baseDir: base.appendingPathComponent("store"))
            let run1 = EvalStore.RunRecord(date: Date(timeIntervalSince1970: 1), harness: "openclaw",
                results: [.init(name: "a", verdict: "pass", reason: "", source: "s"),
                          .init(name: "b", verdict: "pass", reason: "", source: "s")],
                sourceVersions: [:])
            let run2 = EvalStore.RunRecord(date: Date(timeIntervalSince1970: 2), harness: "openclaw",
                results: [.init(name: "a", verdict: "pass", reason: "", source: "s"),
                          .init(name: "b", verdict: "fail", reason: "regressed", source: "s")],
                sourceVersions: [:])
            evalStore.append(run1)
            evalStore.append(run2)
            let history = evalStore.history(harness: "openclaw")
            expect(history.count == 2 && history.first?.passCount == 1, "history persists, newest first")
            expect(EvalStore.regressions(latest: run2, previous: run1) == ["b"],
                   "regression delta identifies the newly failing case")

            // Refine seeding: eval failures reach the refine system prompt.
            final class CapturingProvider: LLMProvider, @unchecked Sendable {
                var capturedSystem = ""
                func complete(system: String, messages: [ChatMessage]) async throws -> String {
                    capturedSystem = system
                    return "What changed?"
                }
                func listModels() async throws -> [String] { [] }
            }
            let capture = CapturingProvider()
            let engine = InterviewEngine(ownerEmail: "t@example.com", today: "2026-07-11")
            if let doc = store2.file(atRelativePath: "memory/pool.md") {
                engine.configureRefine(provider: capture, file: doc, store: store2,
                                       personName: "T",
                                       evalNotes: ["\"Recall pool routine\" (fail): missing fall closure"])
                await engine.start()
                expect(capture.capturedSystem.contains("FAILED")
                       && capture.capturedSystem.contains("missing fall closure"),
                       "refine system prompt carries the eval failure")
            } else {
                expect(false, "seeded memory doc loadable for refine")
            }

            print("\n== eval self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Headless verification of context backfeed (`--backfeedtest`): ledger roundtrip,
    /// deterministic drift detection, reverse heading mapping, guardrail+validation
    /// disposal of scripted LLM responses, and baseline reset on re-push. No network,
    /// no Keychain.
    static func backfeedTest() {
        Task { @MainActor in
            print("== backfeed self-test ==")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            let fm = FileManager.default
            let pid = ProcessInfo.processInfo.processIdentifier
            let base = URL(fileURLWithPath: "/tmp/backfeedtest-\(pid)").resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: base) }
            let target = base.appendingPathComponent("workspace")
            let canonical = base.appendingPathComponent("canonical")
            let ledger = PushLedger(baseDir: base.appendingPathComponent("ledger"))
            try? fm.createDirectory(at: target.appendingPathComponent("memories"),
                                    withIntermediateDirectories: true)
            try? Scaffold.create(at: canonical, copyingTemplatesFrom: nil)

            // Simulate a push: write artifacts + record the ledger.
            let artifacts = [
                BuildArtifact(relativePath: "MEMORY.md", contents: "# Index\n\n- one\n",
                              sourceDescription: "Memory ← MEMORY.md", designation: .pii),
                BuildArtifact(relativePath: "memories/known.md", contents: "known fact\n",
                              sourceDescription: "Memory ← known.md", designation: .pii),
            ]
            for a in artifacts {
                let dst = target.appendingPathComponent(a.relativePath)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? a.contents.write(to: dst, atomically: true, encoding: .utf8)
            }
            ledger.record(harness: "test", target: target, artifacts: artifacts)
            expect(ledger.manifest(harness: "test", target: target).count == 2,
                   "ledger records 2 entries")

            // Clean target → no drift.
            var drift = HarvestScanner.scan(target: target,
                                            manifest: ledger.manifest(harness: "test", target: target)).items
            expect(drift.isEmpty, "no drift right after push")
            expect(ledger.firstPush(harness: "test", target: target) != nil,
                   "v2 ledger stamps a first-push epoch")

            // Agent adds a memory + edits the index → exactly 2 classified items.
            try? "The user prefers espresso over drip coffee.\n"
                .write(to: target.appendingPathComponent("memories/espresso.md"),
                       atomically: true, encoding: .utf8)
            try? "# Index\n\n- one\n- espresso\n"
                .write(to: target.appendingPathComponent("MEMORY.md"),
                       atomically: true, encoding: .utf8)
            drift = HarvestScanner.scan(target: target,
                                        manifest: ledger.manifest(harness: "test", target: target)).items
            expect(drift.count == 2, "2 drift items detected (got \(drift.count))")
            expect(drift.first { $0.relativePath == "memories/espresso.md" }?.kind == .added,
                   "new memory classified as added")
            expect(drift.first { $0.relativePath == "MEMORY.md" }?.kind == .modified,
                   "edited index classified as modified")

            // Reverse heading mapping: harness dialect never lands canonically.
            let harnessDialect = "## Principles\n\ntext\n\n## User\n\nme"
            let reversed = ProposalEngine.reverseIdentityHeadings(harnessDialect)
            expect(reversed.contains("## Operating Principles") && reversed.contains("## User Profile"),
                   "identity headings reversed to canonical")

            // Finalize a scripted response for the added memory → validation-clean
            // proposal with a kebab name-derived path.
            let added = drift.first { $0.kind == .added }!
            let goodResponse = """
            TARGET: memory/entry.md
            RATIONALE: The agent learned a coffee preference worth keeping.
            ---
            ---
            title: Espresso Preference
            designation: PII
            layer: memory
            entry_type: user
            name: espresso-preference
            description: prefers espresso over drip coffee
            owner: t@example.com
            review_cadence: monthly
            last_reviewed: 2026-07-07
            version: 0.1.0
            status: draft
            target_tools: [openclaw]
            ---

            > **Classification: PII** — personal preference.

            ## Classification

            Personal preference — PII.

            ## Entry

            The user prefers espresso over drip coffee.

            ## Source

            Harness memory, harvested 2026-07-07.

            ## Change Log

            - 2026-07-07 · v0.1.0 — created
            """
            let proposal = ProposalEngine.finalize(item: added, harness: "test",
                                                   rawResponse: goodResponse,
                                                   canonicalRoot: canonical, today: "2026-07-07")
            expect(proposal != nil, "valid response yields a proposal")
            expect(proposal?.targetRelativePath == "memory/espresso-preference.md",
                   "path derived from kebab name (got \(proposal?.targetRelativePath ?? "nil"))")
            expect(proposal?.isNewFile == true, "flagged as new file")

            // Update path: existing canonical identity + harness-dialect response with
            // an unbumped version → reversed headings, bumped version, changelog entry.
            let identity = """
            ---
            title: T
            designation: PII
            layer: identity
            owner: t@example.com
            review_cadence: quarterly
            last_reviewed: 2026-01-01
            version: 0.3.0
            status: draft
            target_tools: [openclaw]
            ---

            > **Classification: PII** — test.

            ## Classification

            PII.

            ## Agent Identity

            - Name: Atlas

            ## User Profile

            - Preferred name: T

            ## Operating Principles

            1. Be brief.

            ## Boundaries

            - None.

            ## Style & Tone

            - Terse.

            ## Output Expectations

            - Bullets.

            ## Escalation & Confirmation

            - Ask first.

            ## Change Log

            - 2026-01-01 · v0.3.0 — earlier
            """
            try? identity.write(to: canonical.appendingPathComponent("identity/identity.md"),
                                atomically: true, encoding: .utf8)
            let modified = drift.first { $0.kind == .modified }!
            let updateResponse = """
            TARGET: identity/identity.md
            RATIONALE: Preference change observed in the harness.
            ---
            \(identity.replacingOccurrences(of: "## Agent Identity", with: "## Agent")
                      .replacingOccurrences(of: "- Name: Atlas", with: "- Name: Atlas\n- Coffee: espresso"))
            """
            let update = ProposalEngine.finalize(item: modified, harness: "test",
                                                 rawResponse: updateResponse,
                                                 canonicalRoot: canonical, today: "2026-07-07")
            expect(update != nil, "update response yields a proposal")
            expect(update?.proposedContents.contains("## Agent Identity") == true,
                   "harness heading reversed in update")
            expect(update?.proposedContents.contains("version: 0.4.0") == true,
                   "version bumped past the original")
            expect(update?.proposedContents.contains("v0.4.0") == true,
                   "Change Log carries the new version")
            expect(update?.isNewFile == false, "flagged as update")

            // Garbage in → dropped, not queued.
            expect(ProposalEngine.finalize(item: added, harness: "test",
                                           rawResponse: "TARGET: memory/x.md\nRATIONALE: r\n---\nno frontmatter at all",
                                           canonicalRoot: canonical, today: "2026-07-07") == nil,
                   "non-compliant proposal dropped by validation")
            expect(ProposalEngine.finalize(item: added, harness: "test",
                                           rawResponse: "TARGET: ../../etc/passwd\nRATIONALE: r\n---\nx",
                                           canonicalRoot: canonical, today: "2026-07-07") == nil,
                   "path traversal rejected")
            expect(ProposalEngine.parse("no structure here") == nil, "unparseable response rejected")

            // Dismissal key is stable for identical content.
            expect(added.contentHash == PushLedger.sha256(added.currentText),
                   "drift hash is the content hash (stable dismissal key)")

            // Re-push (record current state) → baseline reset, no drift.
            let repush = [
                BuildArtifact(relativePath: "MEMORY.md",
                              contents: (try? String(contentsOf: target.appendingPathComponent("MEMORY.md"), encoding: .utf8)) ?? "",
                              sourceDescription: "Memory ← MEMORY.md", designation: .pii),
                BuildArtifact(relativePath: "memories/known.md", contents: "known fact\n",
                              sourceDescription: "Memory ← known.md", designation: .pii),
                BuildArtifact(relativePath: "memories/espresso.md",
                              contents: (try? String(contentsOf: target.appendingPathComponent("memories/espresso.md"), encoding: .utf8)) ?? "",
                              sourceDescription: "Memory ← espresso.md", designation: .pii),
            ]
            ledger.record(harness: "test", target: target, artifacts: repush)
            drift = HarvestScanner.scan(target: target,
                                        manifest: ledger.manifest(harness: "test", target: target)).items
            expect(drift.isEmpty, "re-push resets the baseline (no drift)")

            // F15.1 — pre-existing filter: an added file whose creation date predates
            // the first push is vendor stock, skipped with a visible count.
            let stock = target.appendingPathComponent("memories/vendor-stock.md")
            try? "shipped with the harness\n".write(to: stock, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.creationDate: Date(timeIntervalSince1970: 0)],
                                  ofItemAtPath: stock.path)
            let filtered = HarvestScanner.scan(
                target: target,
                manifest: ledger.manifest(harness: "test", target: target),
                firstPush: ledger.firstPush(harness: "test", target: target))
            expect(filtered.items.isEmpty && filtered.preexistingSkipped == 1,
                   "pre-existing file skipped, not drifted (skipped=\(filtered.preexistingSkipped))")
            // Without an epoch (legacy ledger), the filter is inactive.
            let unfiltered = HarvestScanner.scan(
                target: target,
                manifest: ledger.manifest(harness: "test", target: target),
                firstPush: nil)
            expect(unfiltered.items.count == 1 && unfiltered.preexistingSkipped == 0,
                   "nil epoch disables the filter (legacy behavior)")

            // F15.1 — legacy (entry-only) manifest decodes: entries readable, no epoch.
            let legacyLedger = PushLedger(baseDir: base.appendingPathComponent("legacy-ledger"))
            try? fm.createDirectory(at: legacyLedger.baseDir, withIntermediateDirectories: true)
            let legacyJSON = #"{"MEMORY.md": {"sha256": "abc", "source": "Memory ← MEMORY.md"}}"#
            // Reproduce the ledger's own filename scheme via a fresh record probe.
            legacyLedger.record(harness: "probe", target: target, artifacts: [])
            if let probeFile = try? fm.contentsOfDirectory(atPath: legacyLedger.baseDir.path).first {
                let legacyURL = legacyLedger.baseDir
                    .appendingPathComponent(probeFile.replacingOccurrences(of: "probe-", with: "legacy-"))
                try? legacyJSON.write(to: legacyURL, atomically: true, encoding: .utf8)
                // Same target hash suffix, harness "legacy" → the ledger reads it.
                expect(legacyLedger.manifest(harness: "legacy", target: target)["MEMORY.md"]?.sha256 == "abc",
                       "legacy entry-only manifest still decodes")
                expect(legacyLedger.firstPush(harness: "legacy", target: target) == nil,
                       "legacy manifest has no epoch")
                // Upgrading via record() stamps the epoch and keeps entries.
                legacyLedger.record(harness: "legacy", target: target, artifacts: [])
                expect(legacyLedger.firstPush(harness: "legacy", target: target) != nil,
                       "record() upgrades a legacy manifest with an epoch")
                expect(legacyLedger.manifest(harness: "legacy", target: target)["MEMORY.md"]?.sha256 == "abc",
                       "upgrade preserves legacy entries")
            } else {
                expect(false, "legacy ledger probe file created")
            }

            print("\n== backfeed self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Headless verification of multi-document layers (`--multidoctest`): cardinality
    /// table, kebab naming guardrails, name-derived save suggestions for instance
    /// targets (fixed paths for single layers), and duplicate-name validation.
    static func multiDocTest() {
        Task { @MainActor in
            print("== multi-document self-test ==")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            // Cardinality table (product decision, 2026-07-06).
            expect(Layer.identity.cardinality == .single, "identity is single")
            expect(Layer.context.cardinality == .singlePerType, "context is single-per-type")
            for l in [Layer.skills, .memory, .connections, .agents] {
                expect(l.cardinality == .multi, "\(l.rawValue) is multi")
            }

            // Kebab derivation.
            expect(InterviewEngine.kebabCase("Extract Project Architecture") == "extract-project-architecture",
                   "kebab from title case")
            expect(InterviewEngine.kebabCase("extract_project_architecture") == "extract-project-architecture",
                   "kebab fixes underscores")
            expect(InterviewEngine.kebabCase("  Weird -- punctuation!! ") == "weird-punctuation",
                   "kebab collapses punctuation runs")
            expect(InterviewEngine.kebabCase(String(repeating: "long-name-", count: 10)).count <= 40,
                   "kebab caps at 40 chars")

            // Name guardrail on drafts.
            let noName = "---\ntitle: Draft Weekly Update\ndesignation: PII\n---\n\n## Body\n\nx"
            let named = InterviewEngine.ensureInstanceName(noName)
            expect(Frontmatter.split(named).0["name"] == "draft-weekly-update",
                   "missing name derived from title")
            let badName = "---\ntitle: T\nname: Bad_Name Here\n---\n\n## Body\n\nx"
            expect(Frontmatter.split(InterviewEngine.ensureInstanceName(badName)).0["name"] == "bad-name-here",
                   "invalid name kebab-cased")
            let goodName = "---\ntitle: T\nname: already-good\n---\n\n## Body\n\nx"
            expect(InterviewEngine.ensureInstanceName(goodName) == goodName,
                   "valid name passes through untouched")

            // Save suggestions: instance targets derive from the draft's name; fixed
            // targets keep their path even when a draft carries a name.
            let engine = InterviewEngine(ownerEmail: "t@example.com", today: "2026-07-07")
            let skillTarget = InterviewTarget(
                id: "t1", layer: .skills, title: "A Skill",
                templateURL: URL(fileURLWithPath: "/x/skills/skill.template.md"),
                frontmatter: [:], sectionHeadings: ["Trigger"],
                suggestedRelativePath: "skills/skill.md")
            expect(skillTarget.isInstance, "skill template is an instance target")
            engine.configure(provider: OllamaProvider(baseURL: "http://localhost:11434", model: "x"),
                             target: skillTarget, templateText: "", personName: "")
            engine.draft = "---\ntitle: T\nname: extract-project-architecture\n---\n\n## Trigger\n\nx"
            expect(engine.suggestedSavePath() == "skills/extract-project-architecture.md",
                   "instance suggestion derives from name (got \(engine.suggestedSavePath()))")
            engine.draft = "---\ntitle: Draft Weekly Update\n---\n\n## Trigger\n\nx"
            expect(engine.suggestedSavePath() == "skills/draft-weekly-update.md",
                   "instance suggestion falls back to kebab title")

            let identityTarget = InterviewTarget(
                id: "t2", layer: .identity, title: "My Identity",
                templateURL: URL(fileURLWithPath: "/x/identity/identity.template.md"),
                frontmatter: [:], sectionHeadings: ["Agent Identity"],
                suggestedRelativePath: "identity/identity.md")
            expect(!identityTarget.isInstance, "identity is not an instance target")
            engine.configure(provider: OllamaProvider(baseURL: "http://localhost:11434", model: "x"),
                             target: identityTarget, templateText: "", personName: "")
            engine.draft = "---\ntitle: T\nname: sneaky-name\n---\n\n## Agent Identity\n\nx"
            expect(engine.suggestedSavePath() == "identity/identity.md",
                   "single layer keeps its fixed path")

            // Duplicate-name validation on a scratch repo.
            let fm = FileManager.default
            let scratch = URL(fileURLWithPath: "/tmp/multidoc-\(ProcessInfo.processInfo.processIdentifier)")
                .resolvingSymlinksInPath()
            defer { try? fm.removeItem(at: scratch) }
            try? Scaffold.create(at: scratch, copyingTemplatesFrom: nil)
            func seedSkill(_ file: String, name: String) {
                let doc = """
                ---
                title: \(name)
                designation: Enterprise
                layer: skills
                name: \(name)
                owner: t@example.com
                review_cadence: quarterly
                last_reviewed: 2026-07-07
                version: 0.1.0
                status: draft
                target_tools: [openclaw]
                ---

                > **Classification: Enterprise** — test.

                ## Trigger

                x
                """
                try? doc.write(to: scratch.appendingPathComponent("skills/\(file)"),
                               atomically: true, encoding: .utf8)
            }
            seedSkill("a.md", name: "same-name")
            seedSkill("b.md", name: "same-name")
            seedSkill("c.md", name: "unique-name")
            let store = CanonicalStore(rootURL: scratch)
            let dupes = Validator(store: store).duplicateNameFindings()
            expect(dupes.count == 2, "both same-name files flagged (got \(dupes.count))")
            expect(dupes.allSatisfy { $0.1.rule == "layer.duplicate_name" },
                   "rule is layer.duplicate_name")
            expect(!dupes.contains { $0.0.filename == "c.md" }, "unique name not flagged")
            expect(dupes.first?.1.message.contains("also used by") == true,
                   "message names the colliding file")

            // Rename clears both.
            seedSkill("b.md", name: "renamed-now")
            let store2 = CanonicalStore(rootURL: scratch)
            expect(Validator(store: store2).duplicateNameFindings().isEmpty,
                   "rename clears all duplicate findings")

            print("\n== multi-document self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Headless verification of the PII vault (`--vaulttest`): injected keys only —
    /// no Keychain access, no prompts. Covers seal/unseal, snapshot → mutate →
    /// restore byte-identical roundtrips, prune-to-N, ciphertext hygiene (perms +
    /// no plaintext leakage), and passphrase export/import of the key.
    static func vaultTest() {
        Task { @MainActor in
            print("== vault self-test ==")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            let fm = FileManager.default
            let pid = ProcessInfo.processInfo.processIdentifier
            let base = URL(fileURLWithPath: "/tmp/vaulttest-\(pid)").resolvingSymlinksInPath()
            let repo = base.appendingPathComponent("repo")
            let vaultDir = base.appendingPathComponent("vault")
            defer { try? fm.removeItem(at: base) }

            do { try Scaffold.create(at: repo, copyingTemplatesFrom: nil) } catch {
                expect(false, "scaffold repo: \(error.localizedDescription)")
                print("\n== vault self-test FAILED ==")
                exit(1)
            }
            let marker = "PII-MARKER-do-not-leak"
            func seed(_ rel: String, layer: String, body: String) {
                let doc = """
                ---
                title: T
                designation: PII
                layer: \(layer)
                owner: t@example.com
                review_cadence: quarterly
                last_reviewed: 2026-07-07
                version: 0.1.0
                status: draft
                target_tools: [openclaw]
                ---

                > **Classification: PII** — test.

                ## Body

                \(body)
                """
                try? doc.write(to: repo.appendingPathComponent(rel), atomically: true, encoding: .utf8)
            }
            seed("identity/identity.md", layer: "identity", body: marker)
            seed("memory/note.md", layer: "memory", body: "original memory")

            let key = SymmetricKey(size: .bits256)

            // Snapshot + hygiene.
            let id1 = (try? PIIVault.snapshot(repo: repo, into: vaultDir, key: key,
                                              reason: "test")) ?? ""
            expect(!id1.isEmpty, "snapshot created (\(id1))")
            let blob = PIIVault.blobURL(id: id1, in: vaultDir)
            let dirPerms = ((try? fm.attributesOfItem(atPath: vaultDir.path))?[.posixPermissions] as? Int) ?? 0
            let blobPerms = ((try? fm.attributesOfItem(atPath: blob.path))?[.posixPermissions] as? Int) ?? 0
            expect(dirPerms == 0o700, "vault dir is 700 (got \(String(dirPerms, radix: 8)))")
            expect(blobPerms == 0o600, "blob is 600 (got \(String(blobPerms, radix: 8)))")
            if let raw = try? Data(contentsOf: blob) {
                expect(!raw.contains(Data(marker.utf8)), "ciphertext leaks no plaintext content")
                expect(!raw.contains(Data("identity/identity.md".utf8)), "ciphertext leaks no paths")
            } else { expect(false, "blob readable") }

            // List + wrong-key resistance.
            let listed = PIIVault.list(vaultDir: vaultDir, key: key)
            expect(listed.count == 1 && listed.first?.fileCount == 2,
                   "list decrypts header (1 snapshot, 2 files)")
            expect(PIIVault.list(vaultDir: vaultDir, key: SymmetricKey(size: .bits256)).isEmpty,
                   "wrong key lists nothing (no crash)")

            // Mutate + single-file restore → byte-identical.
            let idPath = repo.appendingPathComponent("identity/identity.md")
            let originalBytes = try? Data(contentsOf: idPath)
            try? "clobbered".write(to: idPath, atomically: true, encoding: .utf8)
            _ = try? PIIVault.restore(id: id1, paths: ["identity/identity.md"],
                                      vaultDir: vaultDir, key: key, into: repo)
            expect((try? Data(contentsOf: idPath)) == originalBytes,
                   "single-file restore is byte-identical")

            // Delete + restore-all recovers the file.
            try? fm.removeItem(at: repo.appendingPathComponent("memory/note.md"))
            _ = try? PIIVault.restore(id: id1, vaultDir: vaultDir, key: key, into: repo)
            expect(fm.fileExists(atPath: repo.appendingPathComponent("memory/note.md").path),
                   "restore-all brings back a deleted file")

            // Prune keeps the newest N (same-second ids get a collision suffix).
            _ = try? PIIVault.snapshot(repo: repo, into: vaultDir, key: key, reason: "second")
            _ = try? PIIVault.snapshot(repo: repo, into: vaultDir, key: key, reason: "third")
            let removed = PIIVault.prune(vaultDir: vaultDir, key: key, keep: 2)
            let afterPrune = PIIVault.list(vaultDir: vaultDir, key: key)
            expect(removed == 1 && afterPrune.count == 2, "prune to 2 removed 1")
            expect(afterPrune.first?.reason == "third", "prune kept the newest")

            // Key export/import roundtrip; wrong passphrase fails cleanly.
            if let wrapped = try? VaultKeyExport.wrap(key: key, passphrase: "correct horse",
                                                      iterations: 10_000) {
                let back = try? VaultKeyExport.unwrap(wrapped, passphrase: "correct horse")
                expect(back?.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) },
                       "passphrase export/import recovers the key")
                expect((try? VaultKeyExport.unwrap(wrapped, passphrase: "wrong")) == nil,
                       "wrong passphrase is rejected")
                if let recovered = back {
                    expect(PIIVault.list(vaultDir: vaultDir, key: recovered).count == 2,
                           "recovered key reads existing snapshots")
                }
            } else { expect(false, "key wrap succeeded") }

            // Empty repo → explicit nothing-to-snapshot, not an empty blob.
            let emptyRepo = base.appendingPathComponent("empty")
            try? Scaffold.create(at: emptyRepo, copyingTemplatesFrom: nil)
            do {
                _ = try PIIVault.snapshot(repo: emptyRepo, into: vaultDir, key: key, reason: "x")
                expect(false, "empty repo snapshot should throw")
            } catch VaultError.nothingToSnapshot {
                expect(true, "empty repo → nothingToSnapshot")
            } catch { expect(false, "unexpected error: \(error)") }

            print("\n== vault self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    /// Headless verification of content migration (`--migratetest`): scaffold two repos,
    /// seed the source with content docs, then assert copy keeps originals and move
    /// removes them — templates in both repos untouched throughout.
    static func migrateTest() {
        Task { @MainActor in
            print("== migrate self-test ==")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            let fm = FileManager.default
            let pid = ProcessInfo.processInfo.processIdentifier
            let base = URL(fileURLWithPath: "/tmp/migratetest-\(pid)").resolvingSymlinksInPath()
            let source = base.appendingPathComponent("src")
            let dest = base.appendingPathComponent("dst")
            defer { try? fm.removeItem(at: base) }

            do {
                try Scaffold.create(at: source, copyingTemplatesFrom: nil)
                try Scaffold.create(at: dest, copyingTemplatesFrom: nil)
            } catch {
                expect(false, "scaffold both repos: \(error.localizedDescription)")
                print("\n== migrate self-test FAILED ==")
                exit(1)
            }

            func seed(_ rel: String, layer: String) {
                let doc = """
                ---
                title: Test Doc
                designation: PII
                layer: \(layer)
                owner: t@example.com
                review_cadence: quarterly
                last_reviewed: 2026-07-06
                version: 0.1.0
                status: draft
                target_tools: [openclaw]
                ---

                > **Classification: PII** — test.

                ## Body

                content
                """
                try? doc.write(to: source.appendingPathComponent(rel), atomically: true, encoding: .utf8)
            }
            seed("identity/identity.md", layer: "identity")
            seed("memory/note.md", layer: "memory")
            seed("skills/my-skill.md", layer: "skills")

            expect(Migrator.contentFileCount(in: source) == 3,
                   "counts 3 content docs, excludes templates (got \(Migrator.contentFileCount(in: source)))")

            // Copy: dest gains the docs; source keeps them.
            _ = try? Migrator.migrate(from: source, to: dest, move: false)
            expect(fm.fileExists(atPath: dest.appendingPathComponent("identity/identity.md").path),
                   "copy: identity landed in dest")
            expect(fm.fileExists(atPath: dest.appendingPathComponent("skills/my-skill.md").path),
                   "copy: skill landed in dest")
            expect(fm.fileExists(atPath: source.appendingPathComponent("identity/identity.md").path),
                   "copy: original stays in source")

            // Move: source loses the docs; dest still has them; templates untouched.
            _ = try? Migrator.migrate(from: source, to: dest, move: true)
            expect(!fm.fileExists(atPath: source.appendingPathComponent("identity/identity.md").path),
                   "move: original removed from source")
            expect(fm.fileExists(atPath: dest.appendingPathComponent("memory/note.md").path),
                   "move: doc present in dest")
            expect(fm.fileExists(atPath: source.appendingPathComponent("identity/identity.template.md").path),
                   "move: source template untouched")
            expect(Migrator.contentFileCount(in: source) == 0,
                   "source has no content docs left after move")

            print("\n== migrate self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    private static func fakeTarget() -> InterviewTarget {
        InterviewTarget(id: "fake", layer: .identity, title: "Fake",
                        templateURL: URL(fileURLWithPath: "/tmp/fake.md"),
                        frontmatter: [:], sectionHeadings: ["A", "B"],
                        suggestedRelativePath: "identity/fake.md")
    }

    /// Headless verification of streaming: deterministic engine tests with scripted
    /// providers (delta accumulation + commit, cancel restore, mid-stream error,
    /// retry-after-error), plus — with `--live` — a real multi-delta stream from Ollama.
    static func streamTest() {
        let live = CommandLine.arguments.contains("--live")
        Task { @MainActor in
            print("== Streaming self-test ==  (live: \(live))")
            var failures = 0
            func expect(_ ok: Bool, _ what: String) {
                print("  [\(ok ? "ok" : "FAIL")] \(what)")
                if !ok { failures += 1 }
            }

            // 1. Deltas accumulate and commit as one assistant turn.
            let e1 = InterviewEngine(ownerEmail: "t@e.com", today: "2026-01-01")
            e1.configure(provider: FakeStreamProvider(deltas: ["What ", "is ", "your role?"], delayMs: 5),
                         target: fakeTarget(), templateText: "", personName: "T")
            await e1.start()
            expect(e1.phase == .asking, "streamed question commits → asking")
            expect(e1.transcript.last?.text == "What is your role?", "deltas accumulated in order")
            expect(e1.streamingText.isEmpty, "streaming buffer cleared after commit")

            // 2. Cancel mid-stream on the opening question → idle, nothing recorded.
            let e2 = InterviewEngine(ownerEmail: "t@e.com", today: "2026-01-01")
            e2.configure(provider: FakeStreamProvider(deltas: Array(repeating: "x", count: 10), delayMs: 100),
                         target: fakeTarget(), templateText: "", personName: "T")
            let t2 = Task { await e2.start() }
            try? await Task.sleep(nanoseconds: 250_000_000)
            e2.cancel()
            await t2.value
            expect(e2.phase == .idle && e2.transcript.isEmpty, "cancelled opening question → idle, empty transcript")

            // 3. Cancel mid-answer → user's answer restored to the input box.
            let e3 = InterviewEngine(ownerEmail: "t@e.com", today: "2026-01-01")
            e3.configure(provider: FakeStreamProvider(deltas: ["Q1?", "…"], delayMs: 80),
                         target: fakeTarget(), templateText: "", personName: "T")
            await e3.start()   // Q1 lands (~160ms)
            e3.input = "my important answer"
            let t3 = Task { await e3.send() }
            try? await Task.sleep(nanoseconds: 100_000_000)
            e3.cancel()
            await t3.value
            expect(e3.input == "my important answer", "cancelled send restores the typed answer")
            expect(e3.transcript.filter { $0.role == .user }.isEmpty, "no dangling user turn after cancel")

            // 4. Mid-stream error surfaces as .error with partial discarded; retry works.
            let flaky = FakeStreamProvider.Counter()
            let e4 = InterviewEngine(ownerEmail: "t@e.com", today: "2026-01-01")
            e4.configure(provider: FakeStreamProvider(deltas: ["Recovered?"], delayMs: 5, flakyCounter: flaky),
                         target: fakeTarget(), templateText: "", personName: "T")
            await e4.start()
            var isError = false
            if case .error = e4.phase { isError = true }
            expect(isError, "first attempt errors (flaky provider)")
            expect(e4.canRetry, "retry available after error")
            await e4.retry()
            expect(e4.phase == .asking && e4.transcript.last?.text == "Recovered?",
                   "retry re-issues the same request and succeeds")

            // 5. Live: Ollama streams multiple deltas.
            if live {
                let provider = OllamaProvider(baseURL: "http://localhost:11434", model: "llama3.2")
                var deltaCount = 0
                var total = ""
                do {
                    for try await d in provider.stream(system: "Reply in one short sentence.",
                                                       messages: [ChatMessage(role: .user, content: "Say hello.")]) {
                        deltaCount += 1
                        total += d
                    }
                    expect(deltaCount >= 2, "Ollama streamed \(deltaCount) deltas (≥ 2 = real streaming)")
                    expect(!total.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "streamed text non-empty")
                } catch {
                    expect(false, "live stream failed: \(error.localizedDescription)")
                }
            }

            print("\n== streaming self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    private static func todayString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        return df.string(from: Date())
    }

    /// Headless check that the interview knows what to ask: build every InterviewTarget
    /// from the canonical repo's templates and confirm each one's H2 sections parse.
    /// Run with `--interviewtest` from inside the canonical repo. No network.
    static func interviewTest() {
        let cwd = FileManager.default.currentDirectoryPath
        let store = CanonicalStore(rootURL: URL(fileURLWithPath: cwd))
        print("== interview self-test ==")
        print("canonical root: \(cwd)")

        let targets = InterviewTarget.all(in: store)
        print("discovered \(targets.count) interview target(s):\n")
        var failures = 0
        for t in targets {
            let ok = !t.sectionHeadings.isEmpty
            if !ok { failures += 1 }
            print("  [\(ok ? "ok" : "FAIL")] \(t.title) — \(t.sectionHeadings.count) sections → \(t.suggestedRelativePath)")
            for h in t.sectionHeadings { print("        · \(h)") }
        }

        if targets.isEmpty { failures += 1; print("\n! no targets found — is this an Agent OS repo?") }
        print("\n== interview self-test \(failures == 0 ? "passed" : "FAILED (\(failures))") ==")
        exit(failures == 0 ? 0 : 1)
    }
}
