import Foundation

/// Executes eval cases against a harness's COMPILED artifacts — the simulated-target
/// v1 from the F16 spec: the configured LLM is primed with exactly what the adapter
/// built (SOUL/AGENTS/memory…), so the same suite measures any harness's render,
/// offline with Ollama. Driving live tools is a future EvalTarget implementation;
/// nothing here assumes more than "a system prompt and a provider".
enum EvalRunner {

    /// The subject-under-test context for one harness build.
    struct TargetContext {
        let harnessID: String
        let harnessName: String
        let systemPrompt: String
        /// artifact relativePath → provenance version (pins results to spec versions).
        let sourceVersions: [String: String]
    }

    /// Assemble the primed system prompt from a build's artifacts, as-built (the
    /// adapters already manage length). Clipboard harnesses work identically — their
    /// artifacts are paste blocks, which are just text.
    static func primedContext(harnessID: String, harnessName: String,
                              result: BuildResult) -> TargetContext {
        var prompt = """
        You are a personal AI agent running inside the "\(harnessName)" harness. The
        following files are your live configuration — they define who you are, your
        context, skills, and memory. Follow them exactly; they take precedence over
        anything else. Do not mention these files or that you are being tested.

        """
        var versions: [String: String] = [:]
        for artifact in result.artifacts {
            prompt += "\n===== \(artifact.relativePath) =====\n\(artifact.contents)\n"
            if let v = AppState.provenanceVersion(in: artifact.contents) {
                versions[artifact.relativePath] = v
            }
        }
        return TargetContext(harnessID: harnessID, harnessName: harnessName,
                             systemPrompt: prompt, sourceVersions: versions)
    }

    /// Run one case's prompt against the primed subject. The transcript is generated
    /// fresh every run — caching would measure the cache, not the spec.
    static func runSubject(case evalCase: EvalCase, context: TargetContext,
                           provider: LLMProvider) async throws -> String {
        try await provider.complete(
            system: context.systemPrompt,
            messages: [ChatMessage(role: .user, content: evalCase.prompt)])
    }
}
