import SwiftUI

/// The "Bootstrap my OS" wizard: sequences the interview engine through
/// Identity → Role → Domain → Team → Memory index with carry-forward, then a
/// batch review/save of all drafts. Hosted inside InterviewView's sheet.
struct BootstrapWizardView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var bootstrap: BootstrapEngine
    @ObservedObject var engine: InterviewEngine

    @State private var confirmExit = false
    @State private var saveResults: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch bootstrap.phase {
            case .interviewing:
                interviewBody
            case .review:
                reviewBody
            case .idle:
                EmptyView()
            }
        }
        .confirmationDialog("Exit the bootstrap wizard?", isPresented: $confirmExit, titleVisibility: .visible) {
            if !bootstrap.completed.isEmpty {
                Button("Review \(bootstrap.completed.count) completed draft(s)") {
                    bootstrap.exitEarly(keepDrafts: true)
                }
            }
            Button("Discard everything", role: .destructive) {
                bootstrap.exitEarly(keepDrafts: false)
            }
            Button("Keep going", role: .cancel) {}
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Text("Bootstrap my OS").font(.headline)
            if bootstrap.phase == .interviewing, let t = bootstrap.currentTarget {
                Text("· \(bootstrap.progressText) · \(t.title)")
                    .foregroundStyle(.secondary)
            } else if bootstrap.phase == .review {
                Text("· Review & save").foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: Double(min(bootstrap.currentIndex, bootstrap.steps.count)),
                         total: Double(max(bootstrap.steps.count, 1)))
                .frame(width: 120)
            Button("Exit") { confirmExit = true }
                .buttonStyle(.borderless)
        }
        .padding(12)
    }

    // MARK: Interview phase

    private var interviewBody: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            controls
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(engine.transcript) { turn in
                        bubble(turn)
                    }
                    if engine.phase == .thinking {
                        if !engine.streamingText.isEmpty {
                            HStack {
                                Text(engine.streamingText)
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.secondary.opacity(0.10)))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer(minLength: 60)
                            }
                        }
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(engine.streamingKind == .draft ? "Generating doc…" : "Thinking…")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Cancel") { engine.cancel() }
                                .controlSize(.small)
                        }
                    }
                    if case .error(let msg) = engine.phase {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(msg, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .textSelection(.enabled)
                            Button("Retry") {
                                Task {
                                    if engine.canRetry {
                                        await engine.retry()
                                    } else {
                                        await bootstrap.retryCurrentDoc()
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                    }
                    Color.clear.frame(height: 1).id("wizard-bottom")
                }
                .padding(14)
            }
            .onChange(of: engine.transcript.count) { _, _ in
                withAnimation { proxy.scrollTo("wizard-bottom", anchor: .bottom) }
            }
            .onChange(of: engine.streamingText) { _, _ in
                proxy.scrollTo("wizard-bottom", anchor: .bottom)
            }
        }
    }

    private func bubble(_ turn: InterviewEngine.Turn) -> some View {
        let isUser = turn.role == .user
        return HStack {
            if isUser { Spacer(minLength: 60) }
            Text(turn.text)
                .textSelection(.enabled)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10)))
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 60) }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Type your answer…", text: $engine.input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { if engine.canSend { Task { await engine.send() } } }
                Button {
                    Task { await engine.send() }
                } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(!engine.canSend)
            }
            HStack {
                Button {
                    Task { await bootstrap.skipCurrentDoc() }
                } label: { Label("Skip this doc", systemImage: "forward.end") }
                    .disabled(engine.phase == .thinking)
                Spacer()
                Text("Answer a few questions, then finish the doc — facts carry into the next one.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await bootstrap.finishCurrentDoc() }
                } label: { Label("Finish doc →", systemImage: "checkmark.circle") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!engine.canGenerate)
            }
        }
        .padding(12)
    }

    // MARK: Review phase

    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(bootstrap.completed.count) document(s) ready\(bootstrap.skippedCount > 0 ? " · \(bootstrap.skippedCount) skipped" : ""). Edit anything below, then save all into the canonical repo.")
                        .font(.caption).foregroundStyle(.secondary)

                    ForEach($bootstrap.completed) { $doc in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: doc.target.layer.symbol).foregroundStyle(Color.accentColor)
                                Text(doc.target.title).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("→ \(doc.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                if state.store.fileExists(relativePath: doc.id) {
                                    Label("overwrites", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            TextEditor(text: $doc.draft)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 160)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                    }

                    if !saveResults.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(saveResults, id: \.self) { line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(line.hasPrefix("✗") ? .red : .secondary)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
                    }
                }
                .padding(14)
            }
            Divider()
            HStack {
                Spacer()
                if saveResults.contains(where: { $0.hasPrefix("✓") }) {
                    Button("Done") { bootstrap.reset() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        saveResults = bootstrap.saveAll()
                        state.vaultAutoSnapshot(reason: "bootstrap save")
                    } label: {
                        Label("Save all to canonical", systemImage: "square.and.arrow.down.on.square")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(bootstrap.completed.isEmpty)
                }
            }
            .padding(12)
        }
    }
}
