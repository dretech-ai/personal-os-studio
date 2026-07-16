import Foundation

/// The AI gate on enterprise contributions: before a document may be pushed to the
/// shared repo, the configured model reviews it for embedded personal data and drafts
/// the one-line catalog summary. Advisory verdict, hard consequence: a "hold" disables
/// Push (fix the content or Skip) — same never-trust-then-verify posture as everywhere
/// else. The vet is why this feature requires a provider.
enum EnterpriseVet {

    struct Result: Equatable {
        let share: Bool
        let summary: String
        let concerns: String
    }

    static func prompt(title: String, designation: String, contents: String)
        -> (system: String, user: String) {
        let system = """
        You review documents proposed for an ORGANIZATION-WIDE shared library. The
        library accepts reusable capability definitions (skills, integration patterns,
        domain context) classified Enterprise or Public. It must never receive personal
        data: names of private individuals, personal preferences/habits, home details,
        health/family information, credentials, or anything identifying a specific
        person's private life. Mentions of business roles and org-public facts are fine.

        Review the document and output EXACTLY three lines:

        VERDICT: share | hold
        SUMMARY: <one line describing the capability for the catalog>
        CONCERNS: <what personal or sensitive content you found, or "none">

        Use "hold" whenever personal data is embedded, credentials appear inline, or
        the content is unusable outside its author's personal context.
        """
        let bounded = contents.count > 6_000
            ? String(contents.prefix(6_000)) + "\n…(truncated)…"
            : contents
        let user = """
        Proposed contribution "\(title)" (designation: \(designation)):

        \(bounded)
        """
        return (system, user)
    }

    static func parse(_ raw: String) -> Result? {
        let lines = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let verdictLine = lines.first(where: { $0.uppercased().hasPrefix("VERDICT:") })
        else { return nil }
        let verdict = verdictLine.dropFirst("VERDICT:".count)
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard verdict == "share" || verdict == "hold" else { return nil }
        func line(_ prefix: String) -> String {
            lines.first { $0.uppercased().hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        return Result(share: verdict == "share",
                      summary: line("SUMMARY:"),
                      concerns: line("CONCERNS:"))
    }

    /// Full vet: prompt the provider, parse strictly; unparseable output is a hold
    /// (never fail open into the shared repo).
    static func vet(title: String, designation: String, contents: String,
                    provider: LLMProvider) async -> Result {
        let (system, user) = prompt(title: title, designation: designation, contents: contents)
        do {
            let raw = try await provider.complete(
                system: system, messages: [ChatMessage(role: .user, content: user)])
            return parse(raw)
                ?? Result(share: false, summary: "", concerns: "vet response unparseable — held")
        } catch {
            return Result(share: false, summary: "",
                          concerns: "vet error: \((error as? LLMError)?.errorDescription ?? error.localizedDescription)")
        }
    }
}
