import Foundation

/// Minimal YAML frontmatter handling for canonical Markdown files.
/// We only need flat `key: value` pairs (the schema never nests deeper than that
/// except for `target_tools: [...]`, which we keep as a raw string).
enum Frontmatter {

    /// Split a Markdown document into (frontmatter dict, body-without-frontmatter).
    static func split(_ text: String) -> (fields: [String: String], body: String) {
        guard text.hasPrefix("---") else { return ([:], text) }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return ([:], text)
        }
        var fields: [String: String] = [:]
        var endIndex: Int? = nil
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = i
                break
            }
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes.
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { fields[key] = value }
        }
        guard let end = endIndex else { return ([:], text) }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (fields, body.trimmingCharacters(in: .newlines))
    }

    /// Just the fields.
    static func fields(of text: String) -> [String: String] {
        split(text).fields
    }
}

/// A parsed Markdown body: the leading blockquote banner(s) plus H2 sections.
struct MarkdownSections {
    var banner: String            // leading `>` blockquote lines (classification banner)
    var preamble: String          // any non-heading text before the first H2 (rarely used)
    var sections: [(heading: String, body: String)]

    /// Fetch a section body by its exact H2 heading (case-insensitive).
    func section(_ name: String) -> String? {
        sections.first { $0.heading.compare(name, options: .caseInsensitive) == .orderedSame }?.body
    }

    static func parse(_ body: String) -> MarkdownSections {
        var banner = ""
        var preamble = ""
        var sections: [(String, String)] = []

        var currentHeading: String? = nil
        var currentBody: [String] = []
        var inBanner = true

        func flush() {
            if let h = currentHeading {
                sections.append((h, currentBody.joined(separator: "\n").trimmingCharacters(in: .newlines)))
            }
            currentBody = []
        }

        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inBanner {
                if trimmed.hasPrefix(">") || trimmed.isEmpty {
                    if trimmed.hasPrefix(">") { banner += (banner.isEmpty ? "" : "\n") + line }
                    continue
                } else {
                    inBanner = false
                }
            }

            if trimmed.hasPrefix("## ") {
                flush()
                currentHeading = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if currentHeading == nil {
                if !trimmed.isEmpty { preamble += (preamble.isEmpty ? "" : "\n") + line }
            } else {
                currentBody.append(line)
            }
        }
        flush()

        return MarkdownSections(
            banner: banner.trimmingCharacters(in: .newlines),
            preamble: preamble.trimmingCharacters(in: .newlines),
            sections: sections
        )
    }
}
