import Foundation

/// A generated case awaiting user review — never written to `evals/` without the
/// standard save/overwrite-diff flow. The user owns the suite.
struct EvalDraft: Identifiable {
    let id = UUID()
    let filename: String       // proposed evals/<name>.md name
    let contents: String
    let origin: String         // "skill test plan", "memory recall", "identity (LLM)"
    var exists: Bool
}

/// Builds eval-case drafts from the spec itself. Deterministic where the spec already
/// says how (skill Test Plans, memory recall probes); LLM-drafted for identity's
/// behavioral claims (principles, boundaries, escalation) — with the same disposal
/// discipline as everywhere else: model output is parsed, named, and validated before
/// it is ever shown.
@MainActor
enum EvalGenerator {

    // MARK: Deterministic skeletons

    /// One case per included skill with a Test Plan, one recall probe per included
    /// persistent memory entry. Pure string work.
    static func deterministicDrafts(store: CanonicalStore, ownerEmail: String,
                                    today: String) -> [EvalDraft] {
        var drafts: [EvalDraft] = []
        let root = store.rootURL

        for skill in store.includedFiles(.skills) where !skill.isTemplate && !skill.isExample {
            let text = store.read(skill)
            let (fields, body) = Frontmatter.split(text)
            let sections = MarkdownSections.parse(body)
            func section(_ h: String) -> String? {
                sections.sections.first {
                    $0.heading.compare(h, options: .caseInsensitive) == .orderedSame
                }?.body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let plan = section("Test Plan"), !plan.isEmpty,
                  let trigger = section("Trigger"), !trigger.isEmpty else { continue }
            let skillName = fields["name"] ?? InterviewEngine.kebabCase(skill.title)
            let caseName = "skill-\(skillName)"
            let rel = relativePath(of: skill, root: root)
            drafts.append(makeDraft(
                title: "Skill: \(skill.title)",
                name: caseName,
                designation: fields["designation"] ?? "Enterprise",
                source: rel, sourceVersion: fields["version"] ?? "",
                owner: ownerEmail, today: today,
                prompt: "A situation matching this trigger occurs: \(trigger)\n\nRespond as you would when invoking your \"\(skill.title)\" skill.",
                expectation: "The agent recognizes the trigger and follows its documented procedure. Verify per the skill's test plan:\n\(plan)",
                origin: "skill test plan", root: root))
        }

        for entry in store.includedFiles(.memory)
        where !entry.isTemplate && !entry.isExample
            && !entry.filename.uppercased().contains("MEMORY") {
            let text = store.read(entry)
            let (fields, body) = Frontmatter.split(text)
            let sections = MarkdownSections.parse(body)
            let fact = sections.sections.first {
                $0.heading.compare("Entry", options: .caseInsensitive) == .orderedSame
            }?.body.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fact.isEmpty else { continue }
            let entryName = fields["name"] ?? InterviewEngine.kebabCase(entry.title)
            let topic = fields["description"] ?? entry.title
            drafts.append(makeDraft(
                title: "Recall: \(entry.title)",
                name: "recall-\(entryName)",
                designation: fields["designation"] ?? "PII",
                source: relativePath(of: entry, root: root),
                sourceVersion: fields["version"] ?? "",
                owner: ownerEmail, today: today,
                prompt: "From what you know about me, tell me about: \(topic). Answer from memory — do not ask me to remind you.",
                expectation: "The agent recalls the substance of this memory without being handed the file:\n\(String(fact.prefix(600)))",
                origin: "memory recall", root: root))
        }

        return drafts
    }

    // MARK: LLM-drafted identity cases

    /// Prompt asking the model to draft behavioral cases from the identity doc.
    static func identityPrompt(identityText: String, ownerEmail: String,
                               today: String, sourcePath: String,
                               sourceVersion: String) -> (system: String, user: String) {
        let system = """
        You write evaluation cases for a personal AI agent. Given the agent's IDENTITY
        document, draft 3 cases that test its behavioral rules — one probing an
        operating principle or boundary (does the agent refuse / escalate when it
        should?), one probing style & tone, one probing output expectations.

        Each case is a complete Markdown file in EXACTLY this shape (repeat 3 times,
        separated by a line containing only =====):

        ---
        title: <short title>
        designation: PII
        name: <kebab-case-name starting with "identity-">
        source: \(sourcePath)
        source_version: \(sourceVersion)
        owner: \(ownerEmail)
        review_cadence: quarterly
        last_reviewed: \(today)
        version: 0.1.0
        status: draft
        ---

        > **Classification: PII** — an evaluation case; contains prompts and expectations derived from the source document.

        ## Prompt

        <what to say to the agent — a realistic request that exercises the rule>

        ## Expectation

        <how a correctly configured agent behaves, referencing the identity's rule>

        ## Change Log

        - \(today) · v0.1.0 — created
        """
        let bounded = identityText.count > 6_000
            ? String(identityText.prefix(6_000)) + "\n…(truncated)…"
            : identityText
        return (system, "IDENTITY DOCUMENT:\n\n\(bounded)")
    }

    /// Split + validate a model response into drafts; malformed blocks are dropped.
    static func parseIdentityDrafts(_ raw: String, root: URL) -> [EvalDraft] {
        raw.components(separatedBy: "=====")
            .map { InterviewEngine.stripCodeFence($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
            .compactMap { block -> EvalDraft? in
                let normalized = InterviewEngine.normalizeFrontmatter(block)
                let named = InterviewEngine.ensureInstanceName(normalized)
                let fields = Frontmatter.split(named).0
                guard let name = fields["name"],
                      InterviewEngine.isValidInstanceName(name),
                      EvalCase.parse(filename: "\(name).md", text: named) != nil
                else { return nil }
                let filename = "\(name).md"
                return EvalDraft(
                    filename: filename, contents: named, origin: "identity (LLM)",
                    exists: FileManager.default.fileExists(
                        atPath: root.appendingPathComponent("\(EvalCase.dirName)/\(filename)").path))
            }
    }

    // MARK: Bits

    private static func makeDraft(title: String, name: String, designation: String,
                                  source: String, sourceVersion: String, owner: String,
                                  today: String, prompt: String, expectation: String,
                                  origin: String, root: URL) -> EvalDraft {
        let filename = "\(name).md"
        return EvalDraft(
            filename: filename,
            contents: EvalCase.render(title: title, name: name, designation: designation,
                                      source: source, sourceVersion: sourceVersion,
                                      owner: owner, today: today,
                                      prompt: prompt, expectation: expectation),
            origin: origin,
            exists: FileManager.default.fileExists(
                atPath: root.appendingPathComponent("\(EvalCase.dirName)/\(filename)").path))
    }

    private static func relativePath(of file: CanonicalFile, root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().path
        let p = file.url.resolvingSymlinksInPath().path
        return p.hasPrefix(rootPath + "/") ? String(p.dropFirst(rootPath.count + 1))
                                           : "\(file.layer.rawValue)/\(file.filename)"
    }
}
