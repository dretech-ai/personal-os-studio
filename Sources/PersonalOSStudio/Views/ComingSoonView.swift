import SwiftUI

struct ComingSoonView: View {
    let harness: Harness

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: harness.symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text(harness.name)
                .font(.largeTitle.weight(.semibold))
            Text("Coming soon")
                .font(.title3)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Spacer()
            Text("Today, training targets OpenClaw. The same canonical layers will feed \(harness.name) once its adapter is promoted to active.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    }

    var detail: String {
        switch harness.id {
        case "hermes":
            return "Hermes reads a Markdown workspace much like OpenClaw. Its adapter is drafted in agent_os/adapters/hermes.md and will light up here next."
        case "claude-cowork":
            return "Claude Cowork is Anthropic's agentic mode inside Claude Desktop. It uses paste-based configuration; a guided export flow is planned."
        case "codex":
            return "OpenAI Codex CLI reads AGENTS.md. The Codex adapter is validated in agent_os/adapters/codex.md and will be wired for one-click push."
        default:
            return "This harness will be trainable from your canonical Agent OS layers in a future update."
        }
    }
}
