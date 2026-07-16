import Foundation

// MARK: - Shared HTTP helper

private enum HTTP {
    /// POST `body` as JSON to `url` with `headers`, returning raw response data.
    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw LLMError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.network("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// POST `body` and stream the response line-by-line (NDJSON or SSE `data:` lines).
    /// Non-2xx before the stream starts throws the same `LLMError.http` as `postJSON`.
    static func postForLines(_ url: URL, headers: [String: String], body: [String: Any])
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    req.timeoutInterval = 300

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.network("No HTTP response.")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line + "\n"; if errorBody.count > 2_000 { break } }
                        throw LLMError.http(status: http.statusCode, body: errorBody)
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is LLMError ? error : LLMError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw LLMError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw LLMError.http(status: code, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

/// Pull a nested string value out of parsed JSON via a key path of the form
/// `["choices", 0, "message", "content"]`. Ints index into arrays; strings into dicts.
private func nestedString(_ json: Any, _ path: [Any]) -> String? {
    var node: Any? = json
    for key in path {
        switch key {
        case let i as Int:
            guard let arr = node as? [Any], arr.indices.contains(i) else { return nil }
            node = arr[i]
        case let s as String:
            guard let dict = node as? [String: Any] else { return nil }
            node = dict[s]
        default:
            return nil
        }
    }
    return node as? String
}

// MARK: - OpenAI-compatible (OpenAI + Perplexity)

/// `POST {base}/chat/completions` with a Bearer key. Response:
/// `{ choices: [ { message: { content } } ] }`.
struct OpenAICompatibleProvider: LLMProvider {
    let baseURL: String
    let apiKey: String
    let model: String
    let presetModels: [String]

    func complete(system: String, messages: [ChatMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingKey }
        guard let url = URL(string: baseURL.trimmingSlash + "/chat/completions") else { throw LLMError.badURL }

        var wire: [[String: String]] = []
        if !system.isEmpty { wire.append(["role": "system", "content": system]) }
        wire.append(contentsOf: messages.map { ["role": $0.role.rawValue, "content": $0.content] })

        let body: [String: Any] = ["model": model, "messages": wire, "stream": false]
        let data = try await HTTP.postJSON(url, headers: ["Authorization": "Bearer \(apiKey)"], body: body)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let text = nestedString(json, ["choices", 0, "message", "content"]) else {
            throw LLMError.decoding("missing choices[0].message.content")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw LLMError.empty }
        return trimmed
    }

    func listModels() async throws -> [String] { presetModels }

    /// SSE streaming: `data: {"choices":[{"delta":{"content":"…"}}]}` … `data: [DONE]`.
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingKey }
                    guard let url = URL(string: baseURL.trimmingSlash + "/chat/completions") else { throw LLMError.badURL }
                    var wire: [[String: String]] = []
                    if !system.isEmpty { wire.append(["role": "system", "content": system]) }
                    wire.append(contentsOf: messages.map { ["role": $0.role.rawValue, "content": $0.content] })
                    let body: [String: Any] = ["model": model, "messages": wire, "stream": true]

                    for try await line in HTTP.postForLines(url, headers: ["Authorization": "Bearer \(apiKey)"], body: body) {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data),
                              let delta = nestedString(json, ["choices", 0, "delta", "content"]) else { continue }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Anthropic

/// `POST {base}/messages` with `x-api-key` + `anthropic-version`. Response:
/// `{ content: [ { type: "text", text } ] }`. System prompt is a top-level field.
struct AnthropicProvider: LLMProvider {
    let baseURL: String
    let apiKey: String
    let model: String
    let presetModels: [String]

    func complete(system: String, messages: [ChatMessage]) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingKey }
        guard let url = URL(string: baseURL.trimmingSlash + "/messages") else { throw LLMError.badURL }

        // Anthropic messages must be user/assistant only; system is top-level.
        let wire = messages
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "model": model,
            // On adaptive-thinking models (e.g. claude-sonnet-5) max_tokens covers
            // thinking + text, so leave headroom for full document drafts.
            "max_tokens": 8192,
            "messages": wire,
        ]
        if !system.isEmpty { body["system"] = system }

        let headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
        ]
        let data = try await HTTP.postJSON(url, headers: headers, body: body)
        let json = try JSONSerialization.jsonObject(with: data)
        let text = try Self.extractText(from: json)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw LLMError.empty }
        return trimmed
    }

    /// Pull the reply text out of a Messages API response. `content` is an array of
    /// typed blocks and the text is NOT always first — models with adaptive thinking
    /// on by default (e.g. claude-sonnet-5) lead with a `thinking` block. Concatenate
    /// every `text` block; if none exist, report the stop_reason (e.g. refusal).
    static func extractText(from json: Any) throws -> String {
        guard let dict = json as? [String: Any],
              let content = dict["content"] as? [[String: Any]] else {
            throw LLMError.decoding("missing content array")
        }
        let textBlocks = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
        guard !textBlocks.isEmpty else {
            let stop = dict["stop_reason"] as? String ?? "unknown"
            if stop == "refusal" {
                throw LLMError.network("The model declined this request (stop_reason: refusal). Rephrase and try again.")
            }
            throw LLMError.decoding("no text block in response (stop_reason: \(stop), blocks: \(content.compactMap { $0["type"] as? String }))")
        }
        return textBlocks.joined(separator: "\n")
    }

    func listModels() async throws -> [String] { presetModels }

    /// SSE streaming: `content_block_delta` events carry `delta.text`; ends at `message_stop`.
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingKey }
                    guard let url = URL(string: baseURL.trimmingSlash + "/messages") else { throw LLMError.badURL }
                    let wire = messages
                        .filter { $0.role != .system }
                        .map { ["role": $0.role.rawValue, "content": $0.content] }
                    var body: [String: Any] = [
                        "model": model, "max_tokens": 4096, "messages": wire, "stream": true,
                    ]
                    if !system.isEmpty { body["system"] = system }
                    let headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]

                    loop: for try await line in HTTP.postForLines(url, headers: headers, body: body) {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else { continue }
                        switch type {
                        case "content_block_delta":
                            if let text = nestedString(json, ["delta", "text"]) {
                                continuation.yield(text)
                            }
                        case "message_stop":
                            break loop
                        case "error":
                            let msg = nestedString(json, ["error", "message"]) ?? "stream error"
                            throw LLMError.network(msg)
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Ollama (local)

/// `POST {base}/api/chat` → `{ message: { content } }`; models from `GET {base}/api/tags`.
struct OllamaProvider: LLMProvider {
    let baseURL: String
    let model: String

    func complete(system: String, messages: [ChatMessage]) async throws -> String {
        guard let url = URL(string: baseURL.trimmingSlash + "/api/chat") else { throw LLMError.badURL }

        var wire: [[String: String]] = []
        if !system.isEmpty { wire.append(["role": "system", "content": system]) }
        wire.append(contentsOf: messages.map { ["role": $0.role.rawValue, "content": $0.content] })

        let body: [String: Any] = ["model": model, "messages": wire, "stream": false]
        let data = try await HTTP.postJSON(url, headers: [:], body: body)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let text = nestedString(json, ["message", "content"]) else {
            throw LLMError.decoding("missing message.content")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw LLMError.empty }
        return trimmed
    }

    /// NDJSON streaming: one JSON object per line with `message.content` deltas,
    /// terminated by `"done": true`.
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: baseURL.trimmingSlash + "/api/chat") else { throw LLMError.badURL }
                    var wire: [[String: String]] = []
                    if !system.isEmpty { wire.append(["role": "system", "content": system]) }
                    wire.append(contentsOf: messages.map { ["role": $0.role.rawValue, "content": $0.content] })
                    let body: [String: Any] = ["model": model, "messages": wire, "stream": true]

                    loop: for try await line in HTTP.postForLines(url, headers: [:], body: body) {
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let delta = nestedString(json, ["message", "content"]), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                        if (json["done"] as? Bool) == true { break loop }
                        if let err = json["error"] as? String { throw LLMError.network(err) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [String] {
        guard let url = URL(string: baseURL.trimmingSlash + "/api/tags") else { throw LLMError.badURL }
        let data = try await HTTP.get(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw LLMError.decoding("missing models array")
        }
        return models.compactMap { $0["name"] as? String }
    }
}

// MARK: - Factory

enum ProviderFactory {
    /// Build a provider from current settings. The API key is passed in (from
    /// `LLMSettings`' session cache) — this layer never touches the Keychain.
    static func make(kind: ProviderKind, baseURL: String, model: String, key: String) -> LLMProvider {
        switch kind {
        case .ollama:
            return OllamaProvider(baseURL: baseURL, model: model)
        case .openai, .perplexity:
            return OpenAICompatibleProvider(baseURL: baseURL, apiKey: key, model: model, presetModels: kind.defaultModels)
        case .anthropic:
            return AnthropicProvider(baseURL: baseURL, apiKey: key, model: model, presetModels: kind.defaultModels)
        }
    }
}

private extension String {
    var trimmingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
