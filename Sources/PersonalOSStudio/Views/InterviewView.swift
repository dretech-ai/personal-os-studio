import SwiftUI

/// Sheet that runs the agent interview: pick a target, answer questions, then
/// generate and save a canonical Markdown file.
struct InterviewView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var engine: InterviewEngine
    @ObservedObject var settings: LLMSettings
    @Environment(\.dismiss) var dismiss

    @State private var targets: [InterviewTarget] = []
    @State private var selectedTarget: InterviewTarget?
    @State private var showSave = false
    @State private var saveFilename = ""
    @State private var saveError: String?
    @State private var showProvider = false
    /// Relative path of the file just saved — shown as a banner on the picker so the
    /// user knows it landed and can immediately build the next document.
    @State private var savedNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.bootstrap.phase != .idle {
                BootstrapWizardView(bootstrap: state.bootstrap, engine: engine)
            } else {
                header
                Divider()
                if !settings.isReady {
                    notReady
                } else if engine.target == nil {
                    targetPicker
                } else {
                    interviewBody
                }
            }
        }
        .frame(width: 780, height: 620)
        .onAppear {
            loadTargets()
            // Editor-initiated refine: pick up the pending file and start immediately.
            if let file = state.pendingRefineFile {
                state.pendingRefineFile = nil
                startRefine(file)
            }
            // Browser-initiated "+ New <instance>": preselect that layer's instance
            // template and start immediately.
            if let template = state.pendingCreateTemplate {
                state.pendingCreateTemplate = nil
                if let target = targets.first(where: { $0.templateURL == template.url }) {
                    selectedTarget = target
                    startInterview()
                }
            }
        }
        .alert("Save failed", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
        .sheet(isPresented: $showProvider) {
            ProviderSettingsView(settings: settings)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
            Text("Agent Interview").font(.headline)
            if let t = engine.target {
                Text("· \(t.title)").foregroundStyle(.secondary)
            }
            Spacer()
            if engine.target != nil {
                Button("New interview") { engine.reset() }
                    .buttonStyle(.borderless)
            }
            Button {
                showProvider = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape").font(.caption2)
                    Text(providerBadge).font(.caption2)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Change the LLM provider")
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var providerBadge: String {
        let model = settings.currentModel
        return model.isEmpty ? settings.kind.displayName : "\(settings.kind.displayName) · \(model)"
    }

    // MARK: Not ready

    private var notReady: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.slash").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text("No LLM provider is ready.").font(.headline)
            Text("Pick a provider — local Ollama, or a cloud API key (OpenAI, Perplexity, Anthropic) — then choose a model.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button {
                showProvider = true
            } label: {
                Label("Configure provider…", systemImage: "gearshape.2")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Target picker

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick what to build")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.top, 12)
            Text("The agent will quiz you on the content each file needs, then draft it for your review.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            if let savedNotice {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved **\(savedNotice)**. Pick another file to keep building your OS, or press Done.")
                        .font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.12)))
                .padding(.horizontal, 14)
            }

            if BootstrapEngine.isOffered(in: state.store) {
                Button {
                    Task {
                        await state.bootstrap.start(provider: settings.makeProvider(),
                                                    store: state.store,
                                                    personName: state.personName)
                    }
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bootstrap my OS").fontWeight(.semibold)
                            Text("One guided interview builds Identity → Role → Domain → Team → Memory, carrying facts forward.")
                                .font(.caption2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
            }

            HStack(spacing: 8) {
                Text("Your name")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Your name", text: $state.personName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Text("Your email")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField(AppState.defaultOwnerEmail, text: $state.ownerEmail)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
            }
            .padding(.horizontal, 14)
            Text("Name and email fill generated files — the agent won't ask for them.")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
            if targets.isEmpty {
                Text("No templates found in the canonical repo (\(state.store.rootURL.lastPathComponent)).")
                    .font(.caption).foregroundStyle(.tertiary).padding(14)
            }
            List(targets, selection: Binding(get: { selectedTarget }, set: { selectedTarget = $0 })) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.layer.symbol).foregroundStyle(Color.accentColor).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).fontWeight(.medium)
                        Text("\(t.sectionHeadings.count) sections · → \(t.suggestedRelativePath)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { selectedTarget = t }
                .tag(t)
            }
            .listStyle(.inset)

            let refinable = refinableFiles
            if !refinable.isEmpty {
                Text("Or refine an existing doc")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(refinable) { file in
                            Button {
                                startRefine(file)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: file.layer.symbol).foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(file.title).font(.caption).lineLimit(1)
                                        Text("v\(file.version)").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }

            HStack {
                Spacer()
                Button {
                    startInterview()
                } label: {
                    Label("Start interview", systemImage: "play.fill")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(selectedTarget == nil)
            }
            .padding(14)
        }
    }

    /// Real content docs in the layers the interview knows how to author.
    private var refinableFiles: [CanonicalFile] {
        let layers: [Layer] = [.identity, .context, .skills, .memory]
        return layers.flatMap { state.store.files($0) }
            .filter { !$0.isTemplate && !$0.isExample }
    }

    // MARK: Interview body

    private var interviewBody: some View {
        VStack(spacing: 0) {
            transcriptScroll
            Divider()
            if engine.phase == .drafted {
                draftEditor
            } else if engine.phase == .thinking && engine.streamingKind == .draft {
                streamingDraftPreview
            } else {
                inputBar
            }
        }
    }

    /// The draft filling in live as it streams; becomes the editable editor on finish.
    private var streamingDraftPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Generating file…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { engine.cancel() }
                    .controlSize(.small)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(engine.streamingText)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("draft-tail")
                }
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                .onChange(of: engine.streamingText) { _, _ in
                    proxy.scrollTo("draft-tail", anchor: .bottom)
                }
            }
        }
        .padding(12)
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(engine.transcript) { turn in
                        bubble(turn)
                    }
                    if engine.phase == .thinking && engine.streamingKind == .question {
                        if !engine.streamingText.isEmpty {
                            // Live assistant bubble, growing as tokens stream in.
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
                            Text(engine.streamingKind == .draft ? "Generating file…" : "Thinking…")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Cancel") { engine.cancel() }
                                .controlSize(.small)
                        }
                        .id("thinking")
                    }
                    if case .error(let msg) = engine.phase {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(msg, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .textSelection(.enabled)
                            if engine.canRetry {
                                Button("Retry") { Task { await engine.retry() } }
                                    .controlSize(.small)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: engine.transcript.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: engine.phase) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: engine.streamingText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
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

    private var inputBar: some View {
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
                if engine.phase == .asking {
                    Text("Answer the question, or generate the file when you're ready.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await engine.generateDraft() }
                } label: {
                    Label("Generate file", systemImage: "doc.badge.gearshape")
                }
                .disabled(!engine.canGenerate)
            }
        }
        .padding(12)
    }

    // MARK: Draft editor

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview — edit before saving")
                    .font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button {
                    Task { await engine.generateDraft() }
                } label: { Label("Regenerate", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            TextEditor(text: $engine.draft)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            HStack {
                if let t = engine.target {
                    Text("Saves into \(state.store.rootURL.lastPathComponent)/\(t.suggestedRelativePath)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    saveFilename = engine.suggestedSavePath()
                    showSave = true
                } label: { Label("Save to canonical", systemImage: "square.and.arrow.down") }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(engine.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .sheet(isPresented: $showSave) { saveSheet }
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save canonical file").font(.headline)
            Text("Path relative to the canonical repo root.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("relative/path.md", text: $saveFilename)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            if state.store.fileExists(relativePath: saveFilename.trimmingCharacters(in: .whitespaces)) {
                Label("A file already exists here and will be overwritten.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                DisclosureGroup("Review changes") {
                    let path = saveFilename.trimmingCharacters(in: .whitespaces)
                    let existing = state.store.file(atRelativePath: path).map { state.store.read($0) }
                        ?? (try? String(contentsOf: state.store.rootURL.appendingPathComponent(path), encoding: .utf8))
                        ?? ""
                    DiffView(old: existing, new: engine.draft)
                }
                .font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { showSave = false }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveFilename.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: Actions

    private func loadTargets() {
        targets = InterviewTarget.all(in: state.store)
        if selectedTarget == nil { selectedTarget = targets.first }
    }

    private func startInterview() {
        guard let target = selectedTarget else { return }
        savedNotice = nil
        let templateText = (try? String(contentsOf: target.templateURL, encoding: .utf8)) ?? ""
        engine.configure(provider: settings.makeProvider(), target: target,
                         templateText: templateText, personName: state.personName)
        Task { await engine.start() }
    }

    private func startRefine(_ file: CanonicalFile) {
        let evalNotes = state.pendingRefineEvalNotes
        state.pendingRefineEvalNotes = []
        engine.configureRefine(provider: settings.makeProvider(), file: file,
                               store: state.store, personName: state.personName,
                               findings: state.findings(for: file),
                               evalNotes: evalNotes)
        Task { await engine.start() }
    }

    private func save() {
        let path = saveFilename.trimmingCharacters(in: .whitespaces)
        do {
            try state.store.createFile(relativePath: path, contents: engine.draft)
            state.store.reload()
            showSave = false
            if let f = state.store.file(atRelativePath: path) {
                state.selectedFile = f
                state.buildResult = nil
            }
            state.vaultAutoSnapshot(reason: "interview save")
            // Return to the target picker (not the home window, and never the stale
            // finished transcript) so the user can immediately build more context.
            engine.reset()
            loadTargets()
            savedNotice = path
        } catch {
            showSave = false
            saveError = error.localizedDescription
        }
    }
}
