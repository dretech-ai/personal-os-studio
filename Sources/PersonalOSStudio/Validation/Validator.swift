import Foundation

/// One validation finding against a canonical file.
struct Finding: Identifiable, Equatable {
    enum Severity: Equatable { case error, warning }
    let id = UUID()
    let severity: Severity
    let rule: String
    let message: String

    static func == (a: Finding, b: Finding) -> Bool {
        a.severity == b.severity && a.rule == b.rule && a.message == b.message
    }
}

/// Implements `agent_os/validation/*-checklist.md` as deterministic linting — the
/// "automated linting arrives in a later milestone" those checklists promise.
/// Structural/frontmatter violations are errors; heuristics (leakage, stale review,
/// content-quality counts) are warnings. Templates are never validated; examples only
/// when the store loads them. Pure string work — no LLM, no network.
struct Validator {

    static let designations: Set<String> = ["PII", "Enterprise", "Public"]
    static let statuses: Set<String> = ["draft", "active", "archived"]
    static let knownTools: Set<String> = ["codex", "claude-code", "openclaw", "hermes", "generic", "claude-cowork"]

    /// review_cadence → maximum days since last_reviewed before it's stale.
    static let cadenceWindows: [String: Int] = [
        "weekly": 8, "monthly": 31, "quarterly": 90, "yearly": 366, "annual": 366,
    ]

    let store: CanonicalStore

    // MARK: Entry points

    func validateAll() -> [String: [Finding]] {
        var results: [String: [Finding]] = [:]
        for layer in Layer.allCases {
            for file in store.files(layer) where !file.isTemplate {
                let findings = validate(file)
                if !findings.isEmpty { results[file.id] = findings }
            }
        }
        // Cross-file pass: within a multi layer, two documents claiming the same
        // `name:` silently collide in adapter output (both map to the same generated
        // path) — flag both files. Per-file `validate(_:)` can't see this.
        for (file, finding) in duplicateNameFindings() {
            results[file.id, default: []].append(finding)
        }
        return results
    }

    /// `layer.duplicate_name` errors for every content document whose `name:` is
    /// claimed by another document in the same multi layer.
    func duplicateNameFindings() -> [(CanonicalFile, Finding)] {
        var out: [(CanonicalFile, Finding)] = []
        for layer in Layer.allCases where layer.cardinality == .multi {
            var byName: [String: [CanonicalFile]] = [:]
            for file in store.files(layer) where !file.isTemplate && !file.isExample {
                let (fields, _) = Frontmatter.split(store.read(file))
                if let name = fields["name"], !name.isEmpty {
                    byName[name, default: []].append(file)
                }
            }
            for (name, files) in byName where files.count > 1 {
                for file in files {
                    let others = files.filter { $0.id != file.id }
                        .map(\.filename).sorted().joined(separator: ", ")
                    out.append((file, Finding(
                        severity: .error, rule: "layer.duplicate_name",
                        message: "name \"\(name)\" is also used by \(others) — adapter output would collide")))
                }
            }
        }
        return out
    }

    func validate(_ file: CanonicalFile) -> [Finding] {
        guard !file.isTemplate else { return [] }
        var findings: [Finding] = []
        let raw = store.read(file)
        let (fields, body) = Frontmatter.split(raw)
        let parsed = MarkdownSections.parse(body)

        if isMemoryIndex(file) {
            // The MEMORY.md index is exempt from frontmatter + banner rules per the
            // memory checklist ("No frontmatter — it's an index, not a memory").
            memoryIndexRules(file, fields: fields, raw: raw, into: &findings)
        } else {
            frontmatterRules(file, fields: fields, into: &findings)
            bannerRules(file, fields: fields, body: body, into: &findings)
            sampleRules(file, fields: fields, body: body, into: &findings)
        }
        sectionRules(file, parsed: parsed, fields: fields, body: body, into: &findings)
        layerRules(file, fields: fields, parsed: parsed, into: &findings)
        leakageRules(file, body: body, into: &findings)

        return findings
    }

    private func isMemoryIndex(_ file: CanonicalFile) -> Bool {
        file.layer == .memory && file.filename.uppercased().contains("MEMORY")
    }

    /// Index-specific rules from the memory checklist.
    private func memoryIndexRules(_ file: CanonicalFile, fields: [String: String], raw: String, into findings: inout [Finding]) {
        if !fields.isEmpty {
            findings.append(Finding(severity: .error, rule: "memory.index_frontmatter",
                                    message: "the MEMORY.md index must have no frontmatter (it's an index, not a memory)"))
        }
        if raw.components(separatedBy: "\n").count > 200 {
            findings.append(Finding(severity: .warning, rule: "memory.index_length",
                                    message: "index exceeds 200 lines — it is read every message"))
        }
    }

    // MARK: Shared frontmatter rules

    private func frontmatterRules(_ file: CanonicalFile, fields: [String: String], into findings: inout [Finding]) {
        func error(_ rule: String, _ msg: String) { findings.append(Finding(severity: .error, rule: rule, message: msg)) }
        func warn(_ rule: String, _ msg: String) { findings.append(Finding(severity: .warning, rule: rule, message: msg)) }

        let designation = fields["designation"] ?? ""
        if !Self.designations.contains(designation) {
            error("frontmatter.designation", "designation must be one of PII / Enterprise / Public (got \"\(designation)\")")
        }
        if let layerField = fields["layer"], layerField != file.layer.rawValue {
            error("frontmatter.layer", "layer is \"\(layerField)\" but the file lives in \(file.layer.rawValue)/")
        }
        if (fields["owner"] ?? "").isEmpty {
            error("frontmatter.owner", "owner is missing or empty")
        }
        if (fields["review_cadence"] ?? "").isEmpty {
            error("frontmatter.review_cadence", "review_cadence is not set")
        }
        if let version = fields["version"] {
            if SemVer(version) == nil {
                error("frontmatter.version", "version \"\(version)\" is not valid semver")
            }
        } else {
            error("frontmatter.version", "version is missing")
        }
        if let status = fields["status"], !Self.statuses.contains(status) {
            error("frontmatter.status", "status must be draft / active / archived (got \"\(status)\")")
        } else if fields["status"] == nil {
            error("frontmatter.status", "status is missing")
        }
        let tools = (fields["target_tools"] ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if tools.isEmpty {
            error("frontmatter.target_tools", "target_tools must list at least one tool")
        } else if !tools.contains(where: Self.knownTools.contains) {
            warn("frontmatter.target_tools", "no known tool in target_tools \(tools) — expected one of \(Self.knownTools.sorted())")
        }

        // Stale review (heuristic → warning).
        if let cadence = fields["review_cadence"]?.lowercased(),
           let window = Self.cadenceWindows[cadence],
           let reviewed = fields["last_reviewed"],
           let date = Self.dateFormatter.date(from: reviewed) {
            let age = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
            if age > window {
                warn("governance.stale_review", "last_reviewed \(reviewed) is \(age) days old — exceeds the \(cadence) window (\(window)d)")
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        return df
    }()

    // MARK: Eval cases (F16)

    /// Findings for eval case files under `<root>/evals/`, keyed by filename. Evals
    /// are root-level repo content (like validation/), not canonical layer files, so
    /// they get their own pass: frontmatter completeness, required sections, and a
    /// `source` that resolves to a real canonical doc.
    func evalFindings() -> [String: [Finding]] {
        let dir = store.rootURL.appendingPathComponent(EvalCase.dirName)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [:] }
        var out: [String: [Finding]] = [:]
        for file in entries.sorted() where file.hasSuffix(".md") && !file.contains(".template.") {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(file),
                                         encoding: .utf8) else { continue }
            var findings: [Finding] = []
            func error(_ rule: String, _ msg: String) {
                findings.append(Finding(severity: .error, rule: rule, message: msg))
            }
            let (fields, body) = Frontmatter.split(text)
            let sections = MarkdownSections.parse(body)
            func section(_ h: String) -> String? {
                sections.sections.first {
                    $0.heading.compare(h, options: .caseInsensitive) == .orderedSame
                }?.body.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let name = fields["name"] {
                if name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
                    error("evals.name", "name \"\(name)\" must be kebab-case")
                }
            } else {
                error("evals.name", "eval case has no name field")
            }
            if let source = fields["source"], !source.isEmpty {
                if store.file(atRelativePath: source) == nil {
                    error("evals.source", "source \"\(source)\" does not resolve to a canonical document")
                }
            } else {
                error("evals.source", "source (the measured canonical doc) is missing")
            }
            if !Self.designations.contains(fields["designation"] ?? "") {
                error("evals.designation", "designation must be one of PII / Enterprise / Public")
            }
            if (section("Prompt") ?? "").isEmpty {
                error("evals.prompt", "## Prompt section is missing or empty")
            }
            let hasExpectation = !(section("Expectation") ?? "").isEmpty
            let hasAssertions = !(section("Must Contain") ?? "").isEmpty
                || !(section("Must Not Contain") ?? "").isEmpty
            if !hasExpectation && !hasAssertions {
                error("evals.expectation", "nothing to measure — needs ## Expectation or Must (Not) Contain assertions")
            }
            if !findings.isEmpty { out[file] = findings }
        }
        return out
    }

    // MARK: Structural repair (refine)

    /// The canonical classification banner for a designation — a blockquote that
    /// restates it, matching what `bannerRules` looks for.
    static func classificationBanner(for designation: String) -> String {
        switch designation {
        case "Enterprise":
            return "> **Classification: Enterprise** — internal business information. Keep it within authorized systems and repositories."
        case "Public":
            return "> **Classification: Public** — no sensitive or identifying content; safe to share."
        default:
            return "> **Classification: PII** — contains personal, identifying information. Store it where only you or a trusted vault can read it; never commit to shared repositories."
        }
    }

    /// Body for a synthesized `## Classification` section.
    static func classificationBody(for designation: String) -> String {
        switch designation {
        case "Enterprise":
            return "This file is classified **Enterprise** because it contains internal business information not meant for public distribution."
        case "Public":
            return "This file is classified **Public** because it contains no sensitive or identifying information."
        default:
            return "This file is classified **PII** because it captures personal, identifying details tied to a specific user."
        }
    }

    /// Deterministically repair the structural findings a refine pass is meant to fix
    /// (missing/mismatched classification banner, missing `## Classification` section),
    /// so a non-compliant doc is *guaranteed* to emerge compliant even when a weak model
    /// ignores the instruction. Frontmatter is preserved byte-for-byte; the designation
    /// drives the banner/section text. A no-op when neither finding is present or the
    /// doc already satisfies the rule (idempotent).
    static func repairStructure(draft: String, findings: [Finding]) -> String {
        let rules = Set(findings.map(\.rule))
        let needsBanner = rules.contains("banner.presence") || rules.contains("banner.designation")
        let needsClassification = findings.contains {
            $0.rule == "sections.missing" && $0.message.localizedCaseInsensitiveContains("Classification")
        }
        guard needsBanner || needsClassification else { return draft }

        // Split frontmatter off textually so it survives unchanged.
        let lines = draft.components(separatedBy: "\n")
        var head = ""
        var body = draft
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            head = lines[0...end].joined(separator: "\n") + "\n\n"
            body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        }

        let raw = fields(of: draft)["designation"] ?? "PII"
        let designation = designations.contains(raw) ? raw : "PII"

        // Banner: a designation-bearing blockquote within the first 10 body lines.
        if needsBanner {
            let firstTen = body.components(separatedBy: "\n").prefix(10)
            let hasBanner = firstTen.contains {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix(">") && t.localizedCaseInsensitiveContains(designation)
            }
            if !hasBanner {
                body = classificationBanner(for: designation) + "\n\n" + body
            }
        }

        // Classification section: insert as the first H2 if absent (matches template order).
        if needsClassification,
           !fenceAwareHeadings(of: body).contains(where: {
               $0.compare("Classification", options: .caseInsensitive) == .orderedSame
           }) {
            let section = "## Classification\n\n\(classificationBody(for: designation))\n"
            if let range = body.range(of: "\n## ") {
                body.insert(contentsOf: section + "\n", at: body.index(after: range.lowerBound))
            } else {
                body = body.trimmingCharacters(in: .newlines) + "\n\n" + section
            }
        }

        return head + body + "\n"
    }

    /// Frontmatter fields of a raw document (thin wrapper so static repair can read
    /// the designation without a store).
    private static func fields(of raw: String) -> [String: String] {
        Frontmatter.split(raw).0
    }

    // MARK: Banner rules

    private func bannerRules(_ file: CanonicalFile, fields: [String: String], body: String, into findings: inout [Finding]) {
        let firstTen = body.components(separatedBy: "\n").prefix(10)
        guard let bannerLine = firstTen.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }) else {
            findings.append(Finding(severity: .error, rule: "banner.presence",
                                    message: "no blockquote classification banner within the first 10 lines"))
            return
        }
        if let designation = fields["designation"], Self.designations.contains(designation),
           !bannerLine.localizedCaseInsensitiveContains(designation) {
            findings.append(Finding(severity: .error, rule: "banner.designation",
                                    message: "banner does not restate the frontmatter designation (\(designation))"))
        }
    }

    // MARK: Section rules (template-driven)

    /// H2 headings outside fenced code blocks (``` fences) — the section parser is
    /// fence-blind, but example/output blocks legitimately contain `## ` lines.
    static func fenceAwareHeadings(of body: String) -> [String] {
        var headings: [String] = []
        var inFence = false
        for line in body.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { inFence.toggle(); continue }
            if !inFence && t.hasPrefix("## ") {
                headings.append(String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            }
        }
        return headings
    }

    private func sectionRules(_ file: CanonicalFile, parsed: MarkdownSections, fields: [String: String], body: String, into findings: inout [Finding]) {
        guard let templateHeadings = templateHeadings(for: file, fields: fields) else { return }
        let fileHeadings = Self.fenceAwareHeadings(of: body)

        // Presence + order: template headings must appear as a subsequence, in order.
        var cursor = 0
        var missing: [String] = []
        for wanted in templateHeadings {
            if let idx = fileHeadings[cursor...].firstIndex(where: {
                $0.compare(wanted, options: .caseInsensitive) == .orderedSame
            }) {
                cursor = idx + 1
            } else if fileHeadings.contains(where: { $0.compare(wanted, options: .caseInsensitive) == .orderedSame }) {
                findings.append(Finding(severity: .error, rule: "sections.order",
                                        message: "section \"\(wanted)\" is out of canonical order"))
            } else {
                missing.append(wanted)
            }
        }
        if !missing.isEmpty {
            findings.append(Finding(severity: .error, rule: "sections.missing",
                                    message: "missing canonical section(s): \(missing.joined(separator: ", "))"))
        }

        // Invented sections.
        let canonical = Set(templateHeadings.map { $0.lowercased() })
        let invented = fileHeadings.filter { !canonical.contains($0.lowercased()) }
        if !invented.isEmpty {
            findings.append(Finding(severity: .error, rule: "sections.invented",
                                    message: "section(s) not in the canonical set: \(invented.joined(separator: ", "))"))
        }

        // Change Log reflects the current version (quality → warning).
        if canonical.contains("change log") {
            let changeLog = parsed.section("Change Log") ?? ""
            if changeLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                findings.append(Finding(severity: .warning, rule: "changelog.empty",
                                        message: "Change Log has no entries"))
            } else if let version = fields["version"], !changeLog.contains(version) {
                findings.append(Finding(severity: .warning, rule: "changelog.version",
                                        message: "Change Log does not mention the current version \(version)"))
            }
        }
    }

    /// The canonical H2 set for a file, read from its layer's template in the repo.
    private func templateHeadings(for file: CanonicalFile, fields: [String: String]) -> [String]? {
        // Backlog scaffolds are per-layer worklists, not document templates.
        let templates = store.files(file.layer).filter { $0.isTemplate && !$0.filename.hasPrefix("backlog.") }
        let match: CanonicalFile?
        switch file.layer {
        case .identity:
            match = templates.first { $0.filename.hasPrefix("identity.") }
        case .context:
            let type = fields["context_type"] ?? ""
            match = templates.first { $0.filename.hasPrefix("\(type).") }
        case .skills:
            match = templates.first { $0.filename.hasPrefix("skill.") }
        case .agents:
            match = templates.first { $0.filename.hasPrefix("agent.") }
        case .connections:
            match = templates.first { $0.filename.hasPrefix("connection.") }
        case .memory:
            if file.filename.uppercased().contains("MEMORY") {
                match = templates.first { $0.filename.hasPrefix("MEMORY.") }
            } else if fields["entry_type"] != nil {
                match = templates.first { $0.filename.hasPrefix("persistent.entry.") }
            } else {
                match = templates.first { $0.filename.hasPrefix("working.") }
            }
        }
        guard let template = match else { return nil }
        let (_, body) = Frontmatter.split(store.read(template))
        let headings = MarkdownSections.parse(body).sections.map(\.heading)
        return headings.isEmpty ? nil : headings
    }

    // MARK: Layer-specific rules

    private func layerRules(_ file: CanonicalFile, fields: [String: String], parsed: MarkdownSections, into findings: inout [Finding]) {
        switch file.layer {
        case .identity:
            if fields["designation"] != "PII" {
                findings.append(Finding(severity: .error, rule: "identity.pii",
                                        message: "identity files are always PII (got \"\(fields["designation"] ?? "")\")"))
            }
            if let principles = parsed.section("Operating Principles") {
                let items = principles.components(separatedBy: "\n").filter {
                    let t = $0.trimmingCharacters(in: .whitespaces)
                    return t.hasPrefix("-") || t.range(of: #"^\d+\."#, options: .regularExpression) != nil
                }
                if items.count < 3 || items.count > 7 {
                    findings.append(Finding(severity: .warning, rule: "identity.principles_count",
                                            message: "Operating Principles has \(items.count) rules — the checklist wants 3–7"))
                }
            }
        case .skills:
            if let name = fields["name"] {
                let kebab = name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
                if !kebab || name.count > 40 {
                    findings.append(Finding(severity: .error, rule: "skills.name",
                                            message: "skill name \"\(name)\" must be kebab-case, ≤ 40 chars"))
                }
            } else {
                findings.append(Finding(severity: .error, rule: "skills.name", message: "skill has no name field"))
            }
            if let scope = fields["scope"], !["personal", "project"].contains(scope) {
                findings.append(Finding(severity: .error, rule: "skills.scope",
                                        message: "scope must be personal or project (got \"\(scope)\")"))
            }
        default:
            break
        }
    }

    // MARK: Sample hygiene (examples only)

    private func sampleRules(_ file: CanonicalFile, fields: [String: String], body: String, into findings: inout [Finding]) {
        guard file.isExample else { return }
        if fields["sample"]?.lowercased() != "true" {
            findings.append(Finding(severity: .error, rule: "sample.flag",
                                    message: "example file must set sample: true in frontmatter"))
        }
        if !body.localizedCaseInsensitiveContains("FICTIONAL") {
            findings.append(Finding(severity: .warning, rule: "sample.banner",
                                    message: "example file should open with a FICTIONAL SAMPLE banner"))
        }
    }

    // MARK: Leakage heuristics (warnings)

    private static let leakageIndicators: [(pattern: String, label: String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "email address"),
        (#"(?i)\bI prefer\b"#, "\"I prefer\""),
        (#"(?i)\bmy manager\b"#, "\"my manager\""),
        (#"(?i)\breports to\b"#, "\"reports to\""),
    ]

    private func leakageRules(_ file: CanonicalFile, body: String, into findings: inout [Finding]) {
        // PII indicators only matter in files claiming to be shareable.
        guard file.designation == .enterprise || file.designation == .pub else { return }
        for (pattern, label) in Self.leakageIndicators {
            if body.range(of: pattern, options: .regularExpression) != nil {
                findings.append(Finding(severity: .warning, rule: "leakage.pii_indicator",
                                        message: "possible PII in a \(file.designation.label) file: contains \(label)"))
            }
        }
    }
}
