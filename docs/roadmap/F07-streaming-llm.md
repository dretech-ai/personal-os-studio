# F07 · Streaming LLM responses + provider polish

**Theme:** Interview & LLM · **Priority:** P3 · **Depends on:** — (benefits F05/F06 when present)

## Context

Personal OS Studio's provider layer (`Sources/PersonalOSStudio/LLM/`) is deliberately
non-streaming v1: `LLMProvider.complete(system:messages:) async throws -> String` does one
blocking round trip via `URLSession.shared.data(for:)` (`Providers.swift` — a shared
`HTTP.postJSON` helper, JSONSerialization parsing via a `nestedString` key-path helper).
Three transports: `OllamaProvider` (`POST {base}/api/chat`, `stream:false` →
`message.content`; `GET /api/tags` for models), `OpenAICompatibleProvider` (OpenAI +
Perplexity, `POST {base}/chat/completions`, Bearer key → `choices[0].message.content`),
`AnthropicProvider` (`POST {base}/messages`, `x-api-key` + `anthropic-version: 2023-06-01`,
`max_tokens: 4096` → `content[0].text`).

The interview (`Interview/InterviewEngine.swift`, `Views/InterviewView.swift`) shows a
"Thinking…" spinner while awaiting the full reply — with local Ollama models this can be
many seconds of dead air; identity drafts (long generations) feel worse. There is no
cancel, and an error kills the turn (the transcript keeps the user's answer but retry
means re-typing).

Wire formats for streaming: Ollama chat streams newline-delimited JSON objects
(`{"message":{"content":"…"},"done":false}` per line, final line `"done":true`);
OpenAI-compatible streams SSE (`data: {"choices":[{"delta":{"content":"…"}}]}` … `data:
[DONE]`); Anthropic streams SSE events (`content_block_delta` with
`delta: {type:"text_delta", text:"…"}`, terminated by `message_stop`).

## Goal

Token streaming end-to-end: the interview transcript and draft preview render text as it
generates, with a working Cancel button and a per-turn Retry on failure — across all four
providers, degrading gracefully to non-streaming if a stream fails mid-flight.

## Requirements

1. Extend the protocol with a streaming method, keeping `complete` for callers that want
   blocking behavior:
   `func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>`
   (yields text deltas). Default implementation may wrap `complete` (single yield) so
   conformers can adopt incrementally.
2. Implement real streaming in all three transports using
   `URLSession.shared.bytes(for:)` + line parsing:
   - Ollama: NDJSON lines, `stream: true`, accumulate `message.content` deltas until
     `done: true`.
   - OpenAI-compatible: SSE `data:` lines, `stream: true`, `choices[0].delta.content`,
     stop at `[DONE]`.
   - Anthropic: SSE events, `"stream": true`, yield `content_block_delta.delta.text`,
     stop at `message_stop`; keep `max_tokens` as today.
   Non-2xx before the stream starts must throw the same `LLMError.http` as `complete`
   (read the error body).
3. `InterviewEngine`: `start()`, `send()`, `generateDraft()` consume the stream — a new
   `@Published var streamingText: String` grows as deltas arrive; on completion the turn
   is committed to `transcript` (or `draft`) exactly as today. Phase stays `.thinking`
   while streaming (UI decides how to render).
4. Cancel: keep the running `Task` handle in the engine; a Cancel button (visible during
   `.thinking`) cancels it. A cancelled question-turn removes nothing (user can re-send);
   a cancelled draft keeps the previous draft if any.
5. Retry: on `.error`, show a Retry button that re-issues the last request without
   re-typing (keep the last-sent messages in the engine).
6. UI: the in-progress assistant bubble renders `streamingText` live (auto-scroll
   maintained via the existing `ScrollViewReader` pattern); the draft `TextEditor` fills
   as it streams then becomes editable.
7. Test connection (`ProviderSettingsView`) stays non-streaming. Interview behavior with
   a provider whose stream errors mid-flight: surface `.error` with partial text
   discarded (turns are atomic).

## Files

Modify:
- `Sources/PersonalOSStudio/LLM/LLMProvider.swift` (protocol + default)
- `Sources/PersonalOSStudio/LLM/Providers.swift` (three streaming implementations + shared
  SSE/NDJSON line-reader helper)
- `Sources/PersonalOSStudio/Interview/InterviewEngine.swift` (streaming consumption,
  cancel task handle, retry state)
- `Sources/PersonalOSStudio/Views/InterviewView.swift` (live bubble, Cancel, Retry)

## Architecture constraints

- Keep the transport pattern: shared HTTP helpers, `LLMError` taxonomy, trimmed outputs,
  no third-party dependencies (hand-rolled SSE/NDJSON line parsing over
  `URLSession.AsyncBytes.lines` is sufficient).
- Engine stays `@MainActor`; stream consumption hops to the main actor per delta (deltas
  are small — no batching needed at interview scale).
- Turns remain atomic in the transcript: no partial turns persisted on cancel/error.
- `rtk` shell prefix for verification commands.

## Acceptance criteria

- [ ] With Ollama (`llama3.2`), question text visibly streams into the transcript; drafts
      stream into the preview.
- [ ] Cancel mid-generation returns to a sendable state with no partial turn recorded.
- [ ] Kill the Ollama daemon mid-stream → `.error` with a working Retry (after daemon
      restart) that re-issues without re-typing.
- [ ] OpenAI/Perplexity/Anthropic paths stream when keys are configured (or are verified
      against their documented SSE shapes via the non-2xx error path if no key available).
- [ ] `--interviewtest` and `--selftest` still exit 0; Test connection unchanged.

## Verification

1. `swift build` clean.
2. Live: run an interview against Ollama; observe incremental rendering; time-to-first-
   token should be visibly faster than time-to-full-reply was.
3. `pkill ollama` mid-turn → error + Retry path; restart daemon, Retry succeeds.
4. Headless: `--interviewtest` exit 0. Raw-curl sanity for the Ollama NDJSON shape:
   `curl -N http://localhost:11434/api/chat -d '{"model":"llama3.2","stream":true,"messages":[{"role":"user","content":"hi"}]}' | head -3`.
