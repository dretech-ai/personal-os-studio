import Foundation

/// Scores a subject transcript against a case. Deterministic assertions run first and
/// are final — the judge model grades only the prose expectation and can never
/// override a Must-Contain / Must-Not-Contain failure.
enum EvalJudge {

    struct Verdict: Equatable {
        enum Kind: String, Codable { case pass, fail, partial }
        let kind: Kind
        let reason: String
        /// True when decided by assertions alone (no model involved).
        let deterministic: Bool
    }

    // MARK: Deterministic assertions

    /// Assertion-only verdict, or nil when the prose expectation still needs judging.
    /// - any Must-Not-Contain hit → fail (final)
    /// - any Must-Contain miss → fail (final)
    /// - assertions all pass and there is no expectation → pass (final)
    /// - assertions all pass but an expectation exists → nil (judge decides)
    static func deterministicVerdict(case evalCase: EvalCase, transcript: String) -> Verdict? {
        for banned in evalCase.mustNotContain
        where transcript.localizedCaseInsensitiveContains(banned) {
            return Verdict(kind: .fail,
                           reason: "transcript contains banned text \"\(banned)\"",
                           deterministic: true)
        }
        let missing = evalCase.mustContain.filter {
            !transcript.localizedCaseInsensitiveContains($0)
        }
        if let first = missing.first {
            return Verdict(kind: .fail,
                           reason: "transcript missing required text \"\(first)\"" +
                                   (missing.count > 1 ? " (+\(missing.count - 1) more)" : ""),
                           deterministic: true)
        }
        if evalCase.expectation.isEmpty {
            return Verdict(kind: .pass, reason: "all assertions satisfied", deterministic: true)
        }
        return nil
    }

    // MARK: LLM judge

    /// Fixed, versioned rubric (v1). The judge never shares a conversation with the
    /// subject — it sees only the case and the finished transcript.
    static func judgePrompt(case evalCase: EvalCase, transcript: String) -> (system: String, user: String) {
        let system = """
        You are an impartial evaluator (rubric v1). You are given: the PROMPT a personal
        AI agent received, the EXPECTATION describing how a correctly configured agent
        should behave, and the agent's actual RESPONSE. Judge ONLY whether the response
        meets the expectation — not style, not length, not whether you would answer
        differently.

        Output EXACTLY two lines, nothing else:

        VERDICT: pass | partial | fail
        REASON: <one sentence>
        """
        let bounded = transcript.count > 6_000
            ? String(transcript.prefix(6_000)) + "\n…(truncated)…"
            : transcript
        let user = """
        PROMPT:
        \(evalCase.prompt)

        EXPECTATION:
        \(evalCase.expectation)

        RESPONSE:
        \(bounded)
        """
        return (system, user)
    }

    static func parseVerdict(_ raw: String) -> Verdict? {
        let lines = raw.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let verdictLine = lines.first(where: { $0.uppercased().hasPrefix("VERDICT:") }) else { return nil }
        let value = verdictLine.dropFirst("VERDICT:".count)
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard let kind = Verdict.Kind(rawValue: value) else { return nil }
        let reason = lines.first(where: { $0.uppercased().hasPrefix("REASON:") })
            .map { String($0.dropFirst("REASON:".count)).trimmingCharacters(in: .whitespaces) }
            ?? ""
        return Verdict(kind: kind, reason: reason, deterministic: false)
    }

    /// Full scoring pipeline for one case: assertions, then (only if needed) the judge.
    static func score(case evalCase: EvalCase, transcript: String,
                      provider: LLMProvider) async -> Verdict {
        if let verdict = deterministicVerdict(case: evalCase, transcript: transcript) {
            return verdict
        }
        let (system, user) = judgePrompt(case: evalCase, transcript: transcript)
        do {
            let raw = try await provider.complete(
                system: system, messages: [ChatMessage(role: .user, content: user)])
            return parseVerdict(raw)
                ?? Verdict(kind: .partial, reason: "judge response unparseable", deterministic: false)
        } catch {
            return Verdict(kind: .partial,
                           reason: "judge error: \((error as? LLMError)?.errorDescription ?? error.localizedDescription)",
                           deterministic: false)
        }
    }
}
