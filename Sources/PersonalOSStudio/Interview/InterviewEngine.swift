import Foundation
import Combine

/// Drives a guided Q&A that builds one canonical Markdown file. The engine holds the
/// chosen provider + target, tracks the transcript, asks one question at a time, and on
/// request synthesizes the complete filled-in file from the conversation.
@MainActor
final class InterviewEngine: ObservableObject {
    enum Phase: Equatable {
        case idle          // no interview configured / not started
        case asking        // showing a question, awaiting the user's answer
        case thinking      // awaiting the model
        case drafted       // a file draft is ready to review/save
        case error(String)
    }

    struct Turn: Identifiable {
        let id = UUID()
        let role: ChatMessage.Role
        let text: String
    }

    enum Mode { case create, refine }
    enum RequestKind { case question, draft }

    @Published private(set) var target: InterviewTarget?
    @Published private(set) var transcript: [Turn] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: Mode = .create
    @Published var draft: String = ""
    @Published var input: String = ""
    /// Text of the in-flight response, growing as deltas stream in.
    @Published private(set) var streamingText: String = ""
    /// What the in-flight request is producing (nil when idle).
    @Published private(set) var streamingKind: RequestKind?

    private var currentTask: Task<Void, Never>?
    private var lastRequest: (messages: [ChatMessage], kind: RequestKind)?

    /// Whether a failed request can be re-issued without re-typing.
    var canRetry: Bool { lastRequest != nil }

    private let ownerEmail: String
    private let today: String
    private var provider: LLMProvider?
    private var templateBody: String = ""
    private var personName: String = ""
    /// Facts established by earlier documents in a multi-doc (bootstrap) run —
    /// injected into the system prompt so the agent never re-asks them.
    private var carryForward: String = ""
    /// Refine mode: the doc being refined (bounded excerpt) and its original fields.
    private var currentDocBlock: String = ""
    private var originalFields: [String: String] = [:]
    /// Refine mode: validation findings for the doc, formatted for the prompt (empty
    /// when the doc is clean). Surfaced to the agent so a refine session that follows
    /// a lint knows exactly what to fix.
    private var findingsBlock: String = ""
    /// The same findings, kept raw so the draft can be repaired deterministically
    /// rather than trusting the model to fix structural issues.
    private var refineFindings: [Finding] = []
    /// Eval failures seeding this refine (F16): "case — reason" lines, injected so the
    /// interviewer targets exactly what measured wrong.
    private var evalNotes: [String] = []

    init(ownerEmail: String, today: String) {
        self.ownerEmail = ownerEmail
        self.today = today
    }

    var canSend: Bool {
        if case .thinking = phase { return false }
        return provider != nil && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canGenerate: Bool {
        provider != nil && !transcript.isEmpty && phase != .thinking
    }

    // MARK: Configuration

    /// Reset the engine for a fresh interview against `target`, using `provider`.
    /// `templateText` is the full template file (frontmatter + body) for reference;
    /// `personName` is the user's name (may be empty) used to fill the document.
    /// `carryForward` (optional) holds facts from earlier documents of a bootstrap
    /// run so the agent doesn't re-ask them.
    func configure(provider: LLMProvider, target: InterviewTarget, templateText: String,
                   personName: String, carryForward: String = "") {
        self.provider = provider
        self.target = target
        self.templateBody = templateText
        self.personName = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.carryForward = carryForward
        self.mode = .create
        self.currentDocBlock = ""
        self.originalFields = [:]
        self.findingsBlock = ""
        self.refineFindings = []
        self.evalNotes = []
        transcript = []
        draft = ""
        input = ""
        phase = .idle
    }

    /// The user's answers so far — the facts a bootstrap run carries into later docs.
    var userAnswers: [String] {
        transcript.filter { $0.role == .user }.map(\.text)
    }

    /// Configure a **refine** run against an existing canonical doc: the agent reads
    /// the current content and asks delta questions; the regenerated file bumps the
    /// version, updates last_reviewed, and appends a Change Log entry.
    func configureRefine(provider: LLMProvider, file: CanonicalFile, store: CanonicalStore,
                         personName: String, findings: [Finding] = [],
                         evalNotes: [String] = []) {
        let raw = store.read(file)
        let (fields, body) = Frontmatter.split(raw)
        let parsed = MarkdownSections.parse(body)

        // Synthesize a target from the doc itself (headings drive save path + title).
        let headings = parsed.sections.map(\.heading)
            .filter { $0.compare("Classification", options: .caseInsensitive) != .orderedSame }
        let relative = file.url.path.replacingOccurrences(of: store.rootURL.path + "/", with: "")

        self.provider = provider
        self.target = InterviewTarget(
            id: file.id,
            layer: file.layer,
            title: file.title,
            templateURL: file.url,
            frontmatter: fields,
            sectionHeadings: headings,
            suggestedRelativePath: relative)
        self.templateBody = ""
        self.personName = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.carryForward = ""
        self.originalFields = fields
        self.currentDocBlock = Self.boundedDocBlock(raw)
        self.findingsBlock = Self.formatFindings(findings)
        self.refineFindings = findings
        self.evalNotes = evalNotes
        self.mode = .refine
        transcript = []
        draft = ""
        input = ""
        phase = .idle
    }

    /// Bound the current-doc excerpt shown to the model: full section list, long
    /// section bodies truncated (~400 chars each) once the doc exceeds ~6,000 chars.
    static func boundedDocBlock(_ raw: String) -> String {
        guard raw.count > 6_000 else { return raw }
        let (fields, body) = Frontmatter.split(raw)
        let parsed = MarkdownSections.parse(body)
        var out = "---\n" + fields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n") + "\n---\n\n"
        if !parsed.banner.isEmpty { out += parsed.banner + "\n\n" }
        for (heading, sectionBody) in parsed.sections {
            let clipped = sectionBody.count > 400
                ? String(sectionBody.prefix(400)) + "\n…(truncated)…"
                : sectionBody
            out += "## \(heading)\n\n\(clipped)\n\n"
        }
        return out
    }

    /// Render validation findings as a prompt block the refine agent can act on.
    /// Empty string when the doc is clean (no block is injected).
    static func formatFindings(_ findings: [Finding]) -> String {
        guard !findings.isEmpty else { return "" }
        return findings.map { f in
            let tag = f.severity == .error ? "error" : "warning"
            return "- [\(tag)] \(f.rule): \(f.message)"
        }.joined(separator: "\n")
    }

    /// Clear the interview back to target selection.
    func reset() {
        currentTask?.cancel()
        currentTask = nil
        lastRequest = nil
        streamingText = ""
        streamingKind = nil
        provider = nil
        target = nil
        templateBody = ""
        personName = ""
        carryForward = ""
        currentDocBlock = ""
        originalFields = [:]
        findingsBlock = ""
        refineFindings = []
        evalNotes = []
        mode = .create
        transcript = []
        draft = ""
        input = ""
        phase = .idle
    }

    // MARK: Turn loop

    /// Begin the interview: ask the model for its first question.
    func start() async {
        await run(kind: .question,
                  messages: [ChatMessage(role: .user, content: "Begin the interview. Ask your first question.")])
    }

    /// Submit the current `input` as the user's answer and fetch the next question.
    func send() async {
        guard canSend else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.append(Turn(role: .user, text: text))
        input = ""
        await run(kind: .question, messages: wireMessages())
    }

    /// Ask the model to synthesize the complete Markdown file from the transcript.
    func generateDraft() async {
        guard canGenerate else { return }
        var msgs = wireMessages()
        msgs.append(ChatMessage(role: .user, content: draftInstruction(for: target!)))
        await run(kind: .draft, messages: msgs)
    }

    /// Cancel the in-flight request. Turns are atomic: a cancelled question restores
    /// the user's answer into the input; a cancelled draft keeps the previous draft.
    func cancel() {
        currentTask?.cancel()
    }

    /// Re-issue the last request after an error, without re-typing.
    func retry() async {
        guard let last = lastRequest else { return }
        await run(kind: last.kind, messages: last.messages)
    }

    // MARK: Streaming core

    /// One streamed round trip: deltas accumulate in `streamingText`; on completion
    /// the turn commits to the transcript (or draft) exactly as before.
    private func run(kind: RequestKind, messages: [ChatMessage]) async {
        guard let provider, let target else { return }
        lastRequest = (messages, kind)
        phase = .thinking
        streamingKind = kind
        streamingText = ""
        let system = systemPrompt(for: target)

        let task = Task { [weak self] in
            do {
                for try await delta in provider.stream(system: system, messages: messages) {
                    if Task.isCancelled { break }
                    self?.streamingText += delta
                }
                guard let self else { return }
                if Task.isCancelled {
                    self.handleCancel(kind)
                } else {
                    self.commit(kind)
                }
            } catch {
                guard let self else { return }
                if Task.isCancelled {
                    self.handleCancel(kind)
                } else {
                    self.phase = .error(self.message(from: error))
                }
            }
            self?.streamingKind = nil
        }
        currentTask = task
        await task.value
        currentTask = nil
    }

    private func commit(_ kind: RequestKind) {
        let text = streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
        streamingText = ""
        guard !text.isEmpty else {
            phase = .error(LLMError.empty.errorDescription ?? "Empty response.")
            return
        }
        switch kind {
        case .question:
            transcript.append(Turn(role: .assistant, text: text))
            phase = .asking
        case .draft:
            var out = Self.stripCodeFence(text)
            out = Self.normalizeFrontmatter(out)   // repair a missing opening --- (weak models)
            if mode == .create, target?.isInstance == true {
                out = Self.ensureInstanceName(out) // guarantee a valid kebab-case name:
            }
            if mode == .refine {
                out = Self.enforceRefineGuardrail(
                    draft: out,
                    originalVersion: originalFields["version"] ?? "0.1.0",
                    today: today)
                // Never trust a weak model to add a missing banner/section — repair
                // the flagged structural findings deterministically from the designation.
                out = Validator.repairStructure(draft: out, findings: refineFindings)
            }
            draft = out
            phase = .drafted
        }
    }

    private func handleCancel(_ kind: RequestKind) {
        streamingText = ""
        switch kind {
        case .question:
            // Restore the just-sent answer so nothing is lost.
            if transcript.last?.role == .user, let popped = transcript.popLast() {
                input = popped.text
            }
            phase = transcript.isEmpty ? .idle : .asking
        case .draft:
            // Previous draft (if any) stays; the conversation remains usable.
            phase = draft.isEmpty ? .asking : .drafted
        }
    }

    // MARK: Prompt building

    private func wireMessages() -> [ChatMessage] {
        transcript.map { ChatMessage(role: $0.role, content: $0.text) }
    }

    private func systemPrompt(for target: InterviewTarget) -> String {
        if mode == .refine { return refineSystemPrompt(for: target) }
        let headings = target.sectionHeadings.map { "- \($0)" }.joined(separator: "\n")
        var who = personName.isEmpty
            ? ""
            : "\nThe user's name is \(personName) and their email is \(ownerEmail). " +
              "Use the name directly to fill the file — do NOT ask them for their name.\n"
        if !carryForward.isEmpty {
            who += """

            Already established in earlier documents (do NOT re-ask any of this; \
            use it to inform your questions and the final file):
            \(carryForward)

            """
        }
        return """
        You are an interviewer helping the user author their personal "\(target.layer.title)" \
        canonical Markdown file (the "\(target.title)" file) for an Agent OS.
        \(who)
        Your job is to ask focused questions, one at a time, to gather exactly the content \
        needed to fill in each of these H2 sections:
        \(headings)

        Rules:
        - Ask ONE concise question per turn. Wait for the answer before asking the next.
        - Cover the sections in order; move on once you have enough for a section.
        - Never invent personal details — only use what the user tells you.
        - Keep it conversational and brief; no preamble like "Great question".
        - When you have covered every section, tell the user they can generate the file.
        \(target.isInstance ? """
        - This document is ONE \(target.layer.instanceNoun) among many — early in the \
        conversation, agree on a short kebab-case name for it (lowercase words joined \
        by hyphens, e.g. "draft-weekly-update"). It becomes the file's `name:` and its \
        filename.
        """ : "")

        For reference, this is the template the file must follow (keep its H2 headings verbatim):

        \(templateBody)
        """
    }

    private func refineSystemPrompt(for target: InterviewTarget) -> String {
        let who = personName.isEmpty ? "" :
            "\nThe user's name is \(personName) and their email is \(ownerEmail). Do NOT ask for it.\n"
        var findingsGuidance = ""
        if !findingsBlock.isEmpty {
            findingsGuidance = """

            The validator flagged these compliance problems with the document:
            \(findingsBlock)
            Structural fixes (a missing classification banner or a missing `## Classification` \
            section) are applied automatically when the file is regenerated — do NOT ask the \
            user about them. In your FIRST message, briefly tell the user these will be fixed \
            on save, then ask about genuine CONTENT changes instead. Do not treat a missing \
            section as a question about whether something "changed".

            """
        }
        if !evalNotes.isEmpty {
            findingsGuidance += """

            These evaluation cases FAILED when the compiled document was tested against \
            its own specification:
            \(evalNotes.map { "- \($0)" }.joined(separator: "\n"))
            Your job is to close that gap: probe what the document should say so the \
            measured behavior matches the expectation — or, if the expectation itself is \
            wrong, say so plainly and suggest updating the eval case instead. Start with \
            the failure, not generic delta questions.

            """
        }
        return """
        You are helping the user REFINE their existing "\(target.layer.title)" canonical \
        Markdown file ("\(target.title)"). You have its current content below.
        \(who)\(findingsGuidance)
        Rules:
        - Ask ONE concise delta question per turn: confirm what looks stale, probe what \
          might have changed. NEVER re-ask things the document already answers — only \
          check whether they're still true.
        - Focus on sections the user says changed and on the flagged problems above; \
          leave the rest alone.
        - When the user has described their changes, tell them to generate the file.

        CURRENT DOCUMENT:

        \(currentDocBlock)
        """
    }

    private func refineDraftInstruction(for target: InterviewTarget) -> String {
        let currentVersion = originalFields["version"] ?? "0.1.0"
        return """
        Now produce the complete UPDATED Markdown file.

        Requirements:
        - Output ONLY the file contents — no explanation, no code fences.
        - Keep every section I did NOT ask you to change VERBATIM from the current document.
        - Apply exactly the changes I described in this conversation.
        - Keep every H2 heading; keep the YAML frontmatter fields and the classification banner.
        - Bump the frontmatter `version` (current: \(currentVersion)) — minor bump for \
          content changes, patch for pure corrections. Set `last_reviewed: \(today)`.
        - APPEND one new entry to the `## Change Log` section describing the delta \
          (format: `- \(today) · v<newVersion> — <one-line summary>`). Keep all existing entries.
        \(findingsBlock.isEmpty ? "" : "- Resolve every validator-flagged problem listed in your instructions (e.g. add any missing section or classification banner) so the regenerated file is compliant.")
        """
    }

    /// Deterministic guardrail around the refine draft: never trust the model with
    /// version math. Ensures the version increased (else bumps minor), last_reviewed
    /// is today, and the Change Log contains an entry for the final version.
    static func enforceRefineGuardrail(draft: String, originalVersion: String, today: String) -> String {
        var lines = draft.components(separatedBy: "\n")
        let original = SemVer(originalVersion) ?? SemVer(major: 0, minor: 1, patch: 0)

        // Locate frontmatter bounds.
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return draft }

        // Version: parse the draft's, bump if not greater than the original.
        var finalVersion = original.bumpedMinor
        if let vIdx = lines[1..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("version:") }) {
            let value = lines[vIdx].components(separatedBy: ":").dropFirst().joined(separator: ":")
            if let drafted = SemVer(value), drafted > original {
                finalVersion = drafted
            } else {
                lines[vIdx] = "version: \(finalVersion)"
            }
        } else {
            lines.insert("version: \(finalVersion)", at: end)
        }

        // last_reviewed: force today.
        if let rIdx = lines[1..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("last_reviewed:") }) {
            lines[rIdx] = "last_reviewed: \(today)"
        }

        var text = lines.joined(separator: "\n")

        // Change Log must mention the final version; append an entry if missing.
        let entry = "- \(today) · v\(finalVersion) — refined via interview"
        if let clRange = text.range(of: "## Change Log") {
            let after = text[clRange.upperBound...]
            if !after.contains("v\(finalVersion)") && !after.contains("\(finalVersion) ") {
                // Insert right after the heading line.
                if let lineEnd = text[clRange.upperBound...].firstIndex(of: "\n") {
                    text.insert(contentsOf: "\n\n\(entry)", at: lineEnd)
                } else {
                    text += "\n\n\(entry)"
                }
            }
        } else {
            text = text.trimmingCharacters(in: .newlines) + "\n\n## Change Log\n\n\(entry)\n"
        }
        return text
    }

    private func draftInstruction(for target: InterviewTarget) -> String {
        if mode == .refine { return refineDraftInstruction(for: target) }
        return """
        Now produce the complete Markdown file from everything I've told you.

        Requirements:
        - Output ONLY the file contents — no explanation, no code fences around it.
        - Reproduce the template's YAML frontmatter, replacing every <placeholder>:
          set `owner: \(ownerEmail)`, `last_reviewed: \(today)`, `version: 0.1.0`, `status: draft`.
        \(personName.isEmpty ? "" : "- Replace every <Your name> token (frontmatter title, User Profile, etc.) with \"\(personName)\".")
        - Remove all template HTML comments (<!-- ... -->).
        - Keep every H2 heading exactly as named in the template.
        - Fill each section with the content I provided. For anything I didn't cover, \
          write a brief reasonable placeholder rather than leaving a <placeholder> token.
        \(target.isInstance ? "- Set the frontmatter `name:` to the kebab-case name we agreed on (lowercase, hyphen-separated, ≤ 40 chars)." : "")
        """
    }

    // MARK: Instance naming (multi layers)

    /// Kebab-case a free-form string per the validator's `skills.name` rule:
    /// lowercase, non-alphanumeric runs → "-", trimmed, ≤ 40 chars.
    static func kebabCase(_ s: String) -> String {
        var out = ""
        var lastDash = true   // suppress leading dash
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 40 {
            out = String(out.prefix(40))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }

    static func isValidInstanceName(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
            && s.count <= 40
    }

    /// Deterministic naming guardrail for instance documents (skills, memory entries,
    /// connections, agents): guarantee the draft carries a valid kebab-case `name:`.
    /// A valid model-provided name passes through; an invalid one is kebab-cased;
    /// a missing one is derived from `title:`. Never trust the model to get it right.
    static func ensureInstanceName(_ draft: String) -> String {
        var lines = draft.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return draft }

        func value(of line: String) -> String {
            line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                .trimmingCharacters(in: .whitespaces)
        }

        if let nIdx = lines[1..<end].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("name:") }) {
            let current = value(of: lines[nIdx])
            if isValidInstanceName(current) { return draft }
            let fixed = kebabCase(current)
            lines[nIdx] = "name: \(fixed.isEmpty ? "untitled" : fixed)"
            return lines.joined(separator: "\n")
        }

        // No name at all — derive from the title (sans possessives/quotes).
        let title = lines[1..<end].first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("title:") }
            .map(value) ?? ""
        let derived = kebabCase(title)
        lines.insert("name: \(derived.isEmpty ? "untitled" : derived)", at: end)
        return lines.joined(separator: "\n")
    }

    /// Where the save sheet should suggest writing the current draft. Instance targets
    /// derive the filename from the draft's own `name:` (never the template base);
    /// everything else keeps the target's fixed path (refine: the doc's own path).
    func suggestedSavePath() -> String {
        guard let target else { return "" }
        guard mode == .create, target.isInstance, !draft.isEmpty else {
            return target.suggestedRelativePath
        }
        let (fields, _) = Frontmatter.split(draft)
        let name = fields["name"].flatMap { Self.isValidInstanceName($0) ? $0 : nil }
            ?? Self.kebabCase(fields["title"] ?? "")
        guard !name.isEmpty else { return target.suggestedRelativePath }
        return "\(target.layer.rawValue)/\(name).md"
    }

    /// Restore the opening `---` when a model emits frontmatter without it (llama3.2
    /// does this). If the draft starts with YAML `key: value` lines terminated by a
    /// `---`, the leading block is unfenced frontmatter → prepend the delimiter so it
    /// parses (otherwise `designation` etc. read as empty → "Unknown" + a wall of
    /// validation errors). No-op when the draft already opens with `---` or the leading
    /// block doesn't look like YAML.
    static func normalizeFrontmatter(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("---") else { return text }
        var lines = trimmed.components(separatedBy: "\n")
        let keyPattern = #"^[A-Za-z_][A-Za-z0-9_-]*\s*:"#
        guard let first = lines.first,
              first.range(of: keyPattern, options: .regularExpression) != nil,
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return text }
        // Everything before the closing --- must look like YAML (keys / list items / blank).
        let looksYAML = lines[0..<close].allSatisfy { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.isEmpty
                || t.range(of: keyPattern, options: .regularExpression) != nil
                || t.hasPrefix("- ")
        }
        guard looksYAML else { return text }
        lines.insert("---", at: 0)
        return lines.joined(separator: "\n")
    }

    /// Strip a leading/trailing ``` or ```markdown fence if the model wrapped the file.
    static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        var lines = s.components(separatedBy: "\n")
        lines.removeFirst()                       // drop opening fence line
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        s = lines.joined(separator: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func message(from error: Error) -> String {
        (error as? LLMError)?.errorDescription ?? error.localizedDescription
    }
}
