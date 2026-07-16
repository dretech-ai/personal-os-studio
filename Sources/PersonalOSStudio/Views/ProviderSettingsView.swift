import SwiftUI

/// Sheet for choosing an LLM provider, entering its API key, picking a model,
/// and testing connectivity with a one-token round trip.
struct ProviderSettingsView: View {
    @ObservedObject var settings: LLMSettings
    @Environment(\.dismiss) var dismiss

    @State private var keyField: String = ""
    @State private var baseURLField: String = ""
    @State private var modelField: String = ""
    @State private var ollamaModels: [String] = []
    @State private var testResult: TestResult?
    @State private var busy = false

    enum TestResult: Equatable {
        case ok(String)
        case fail(String)
    }

    private var kind: ProviderKind { settings.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "gearshape.2.fill").foregroundStyle(Color.accentColor)
                Text("LLM Provider").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    providerPicker
                    if kind.requiresKey { keySection }
                    baseURLSection
                    modelSection
                    testSection
                }
                .padding(16)
            }
        }
        .frame(width: 520, height: 540)
        .onAppear(perform: loadFields)
        .onChange(of: settings.kind) { _, _ in loadFields() }
    }

    // MARK: Provider

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Provider")
            Picker("", selection: Binding(
                get: { settings.kind },
                set: { settings.kind = $0; testResult = nil })) {
                ForEach(ProviderKind.allCases) { k in Text(k.displayName).tag(k) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    // MARK: API key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label("API key")
                Spacer()
                if settings.hasKey(for: kind) {
                    Label("stored", systemImage: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
            HStack {
                SecureField(settings.hasKey(for: kind) ? "•••••••• (stored — type to replace)" : "Paste your API key", text: $keyField)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    settings.setKey(keyField, for: kind)
                    keyField = ""
                    testResult = nil
                }
                .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                if settings.hasKey(for: kind) {
                    Button(role: .destructive) {
                        settings.setKey("", for: kind)
                        testResult = nil
                    } label: { Image(systemName: "trash") }
                    .help("Remove stored key")
                }
            }
            if let hint = kind.keyHint {
                Text("Get a key at \(hint) — stored securely in your macOS Keychain.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Base URL

    private var baseURLSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Base URL")
            TextField(kind.defaultBaseURL, text: $baseURLField)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit { settings.setBaseURL(baseURLField, for: kind) }
            Text("Override only if your endpoint differs from the default.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label("Model")
                Spacer()
                if kind == .ollama {
                    Button {
                        Task { await refreshOllamaModels() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Reload models from the local Ollama daemon")
                }
            }
            let presets = kind == .ollama ? ollamaModels : kind.defaultModels
            if !presets.isEmpty {
                Picker("", selection: Binding(
                    get: { presets.contains(modelField) ? modelField : "__custom" },
                    set: { newValue in
                        if newValue != "__custom" {
                            modelField = newValue
                            settings.setModel(newValue, for: kind)
                            testResult = nil
                        }
                    })) {
                    ForEach(presets, id: \.self) { Text($0).tag($0) }
                    Text("Custom…").tag("__custom")
                }
                .labelsHidden()
            }
            TextField("model id", text: $modelField)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit { settings.setModel(modelField, for: kind); testResult = nil }
            if kind == .ollama && ollamaModels.isEmpty {
                Text("No models loaded yet — click ↻ to query the local daemon (ollama serve).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Test

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text(busy ? "Testing…" : "Test connection")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(busy || modelField.trimmingCharacters(in: .whitespaces).isEmpty)

            switch testResult {
            case .ok(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .fail(let msg):
                Label(msg, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            case nil:
                EmptyView()
            }
        }
    }

    // MARK: Actions

    private func loadFields() {
        baseURLField = settings.baseURL(for: kind)
        modelField = settings.model(for: kind)
        keyField = ""
        testResult = nil
        if kind == .ollama && ollamaModels.isEmpty {
            Task { await refreshOllamaModels() }
        }
    }

    private func refreshOllamaModels() async {
        // Persist any pending base-URL edit first.
        settings.setBaseURL(baseURLField, for: .ollama)
        let provider = OllamaProvider(baseURL: settings.baseURL(for: .ollama), model: modelField)
        do {
            let models = try await provider.listModels()
            ollamaModels = models
            if modelField.isEmpty, let first = models.first {
                modelField = first
                settings.setModel(first, for: .ollama)
            }
        } catch {
            testResult = .fail((error as? LLMError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func testConnection() async {
        busy = true
        testResult = nil
        // Persist current field edits so the provider we build reflects the UI.
        settings.setBaseURL(baseURLField, for: kind)
        settings.setModel(modelField, for: kind)
        let provider = settings.makeProvider()
        do {
            let reply = try await provider.complete(
                system: "You are a connectivity check. Reply with a single word.",
                messages: [ChatMessage(role: .user, content: "Reply with the word: ok")]
            )
            testResult = .ok("Connected · \(kind.displayName) · \(modelField) replied “\(reply.prefix(40))”")
        } catch {
            testResult = .fail((error as? LLMError)?.errorDescription ?? error.localizedDescription)
        }
        busy = false
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}
