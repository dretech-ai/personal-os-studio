import Foundation

/// One measurable claim about the personal OS, stored as portable Markdown under
/// `<canonical>/evals/*.md` (a root-level directory like `validation/`, not a layer).
/// A case says: given `Prompt`, a harness trained from `source` should behave per
/// `Expectation` — with optional deterministic `Must Contain` / `Must Not Contain`
/// assertions that are checked in code before any judge sees the transcript.
struct EvalCase: Identifiable, Equatable {
    let filename: String          // e.g. "recall-pool-routine.md"
    let name: String              // kebab-case frontmatter name
    let title: String
    /// Layer-relative path of the canonical doc this case measures.
    let source: String
    let sourceVersion: String
    let prompt: String
    let expectation: String
    let mustContain: [String]
    let mustNotContain: [String]

    var id: String { filename }

    static let dirName = "evals"

    // MARK: Parse

    /// Parse a case from raw file text. Returns nil when the required pieces
    /// (frontmatter name/source, Prompt, Expectation-or-assertions) are absent —
    /// the validator reports *why* separately.
    static func parse(filename: String, text: String) -> EvalCase? {
        let (fields, body) = Frontmatter.split(text)
        let sections = MarkdownSections.parse(body)
        func section(_ heading: String) -> String? {
            sections.sections.first {
                $0.heading.compare(heading, options: .caseInsensitive) == .orderedSame
            }?.body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func items(_ heading: String) -> [String] {
            (section(heading) ?? "").components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        guard let name = fields["name"], !name.isEmpty,
              let source = fields["source"], !source.isEmpty,
              let prompt = section("Prompt"), !prompt.isEmpty else { return nil }
        let expectation = section("Expectation") ?? ""
        let mustContain = items("Must Contain")
        let mustNotContain = items("Must Not Contain")
        guard !expectation.isEmpty || !mustContain.isEmpty || !mustNotContain.isEmpty else {
            return nil   // nothing to measure against
        }
        return EvalCase(filename: filename,
                        name: name,
                        title: fields["title"] ?? name,
                        source: source,
                        sourceVersion: fields["source_version"] ?? "",
                        prompt: prompt,
                        expectation: expectation,
                        mustContain: mustContain,
                        mustNotContain: mustNotContain)
    }

    /// All parseable cases in `<root>/evals/`, sorted by filename.
    static func loadAll(root: URL) -> [EvalCase] {
        let dir = root.appendingPathComponent(dirName)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return [] }
        return entries.sorted()
            .filter { $0.hasSuffix(".md") && !$0.contains(".template.") }
            .compactMap { file in
                guard let text = try? String(contentsOf: dir.appendingPathComponent(file),
                                             encoding: .utf8) else { return nil }
                return parse(filename: file, text: text)
            }
    }

    // MARK: Serialize

    /// Render a complete case file (used by the generator; hand-edits are normal
    /// Markdown edits afterwards).
    static func render(title: String, name: String, designation: String, source: String,
                       sourceVersion: String, owner: String, today: String,
                       prompt: String, expectation: String,
                       mustContain: [String] = [], mustNotContain: [String] = []) -> String {
        var out = """
        ---
        title: \(title)
        designation: \(designation)
        name: \(name)
        source: \(source)
        source_version: \(sourceVersion)
        owner: \(owner)
        review_cadence: quarterly
        last_reviewed: \(today)
        version: 0.1.0
        status: draft
        ---

        > **Classification: \(designation)** — an evaluation case; contains prompts and expectations derived from the source document.

        ## Prompt

        \(prompt)

        ## Expectation

        \(expectation)

        """
        if !mustContain.isEmpty {
            out += "\n## Must Contain\n\n" + mustContain.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !mustNotContain.isEmpty {
            out += "\n## Must Not Contain\n\n" + mustNotContain.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        out += "\n## Change Log\n\n- \(today) · v0.1.0 — created\n"
        return out
    }
}
