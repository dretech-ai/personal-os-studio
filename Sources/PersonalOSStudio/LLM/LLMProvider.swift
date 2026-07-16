import Foundation

// MARK: - Provider kinds

/// The LLM providers Studio can talk to. Ollama is local (no key); the rest are
/// cloud APIs authenticated with an API key.
enum ProviderKind: String, CaseIterable, Identifiable {
    case ollama
    case openai
    case perplexity
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama (local)"
        case .openai: return "OpenAI"
        case .perplexity: return "Perplexity"
        case .anthropic: return "Anthropic"
        }
    }

    /// Cloud providers need an API key; Ollama runs locally.
    var requiresKey: Bool { self != .ollama }

    /// Default base URL. Editable in settings for OpenAI-compatible / local endpoints.
    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434"
        case .openai: return "https://api.openai.com/v1"
        case .perplexity: return "https://api.perplexity.ai"
        case .anthropic: return "https://api.anthropic.com/v1"
        }
    }

    /// Model presets shown in the picker (users can also type a custom id).
    /// Ollama models are discovered live via `listModels`, so its preset is empty.
    var defaultModels: [String] {
        switch self {
        case .ollama: return []
        case .openai: return ["gpt-4o", "gpt-4o-mini"]
        case .perplexity: return ["sonar", "sonar-pro"]
        case .anthropic: return ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5"]
        }
    }

    /// A sensible default model to preselect.
    var defaultModel: String { defaultModels.first ?? "" }

    /// Where to get an API key, shown as a hint in settings.
    var keyHint: String? {
        switch self {
        case .ollama: return nil
        case .openai: return "platform.openai.com/api-keys"
        case .perplexity: return "perplexity.ai/settings/api"
        case .anthropic: return "console.anthropic.com"
        }
    }
}

// MARK: - Messages

struct ChatMessage {
    enum Role: String { case system, user, assistant }
    let role: Role
    let content: String
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case missingKey
    case badURL
    case http(status: Int, body: String)
    case decoding(String)
    case network(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key set for this provider."
        case .badURL: return "The provider base URL is invalid."
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(status): \(trimmed.isEmpty ? "(no body)" : String(trimmed.prefix(300)))"
        case .decoding(let msg): return "Could not parse the response: \(msg)"
        case .network(let msg): return msg
        case .empty: return "The model returned an empty response."
        }
    }
}

// MARK: - Provider protocol

/// One chat-completion round trip plus model discovery. Non-streaming for v1.
protocol LLMProvider: Sendable {
    /// Send a conversation and return the assistant's reply text (blocking round trip).
    func complete(system: String, messages: [ChatMessage]) async throws -> String
    /// Stream the assistant's reply as text deltas. Implementations without native
    /// streaming inherit the default (a single yield of the full reply).
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
    /// List available model ids (live for Ollama; presets for cloud providers).
    func listModels() async throws -> [String]
}

extension LLMProvider {
    /// Default: wrap the blocking call as a single-delta stream.
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await complete(system: system, messages: messages)
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
