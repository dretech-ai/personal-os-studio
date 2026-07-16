import Foundation
import Combine

/// Persisted LLM configuration: selected provider, per-provider model, and optional
/// base-URL override. Non-secret prefs live in UserDefaults; API keys live in the
/// Keychain (see `Keychain`) and are accessed via `setKey`/`hasKey`.
@MainActor
final class LLMSettings: ObservableObject {
    @Published var kind: ProviderKind {
        didSet { defaults.set(kind.rawValue, forKey: Keys.kind) }
    }

    /// Per-provider selected model, keyed by provider id.
    @Published private(set) var models: [String: String]

    /// Per-provider base-URL override, keyed by provider id (empty = use default).
    @Published private(set) var baseURLs: [String: String]

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let kind = "llm.kind"
        static let models = "llm.models"
        static let baseURLs = "llm.baseURLs"
    }

    init() {
        let savedKind = defaults.string(forKey: Keys.kind).flatMap(ProviderKind.init) ?? .ollama
        self.kind = savedKind
        self.models = (defaults.dictionary(forKey: Keys.models) as? [String: String]) ?? [:]
        self.baseURLs = (defaults.dictionary(forKey: Keys.baseURLs) as? [String: String]) ?? [:]
    }

    // MARK: Model

    /// Selected model for a provider, falling back to its default preset.
    func model(for kind: ProviderKind) -> String {
        let saved = models[kind.rawValue] ?? ""
        return saved.isEmpty ? kind.defaultModel : saved
    }

    func setModel(_ model: String, for kind: ProviderKind) {
        models[kind.rawValue] = model
        defaults.set(models, forKey: Keys.models)
    }

    var currentModel: String { model(for: kind) }

    // MARK: Base URL

    /// Effective base URL for a provider (override if set, else the default).
    func baseURL(for kind: ProviderKind) -> String {
        let saved = baseURLs[kind.rawValue] ?? ""
        return saved.isEmpty ? kind.defaultBaseURL : saved
    }

    func setBaseURL(_ url: String, for kind: ProviderKind) {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        // Store empty to mean "use default", so users can reset to the preset.
        baseURLs[kind.rawValue] = (trimmed == kind.defaultBaseURL) ? "" : trimmed
        defaults.set(baseURLs, forKey: Keys.baseURLs)
    }

    var currentBaseURL: String { baseURL(for: kind) }

    // MARK: API keys (Keychain-backed, session-cached)

    /// Per-launch cache of keychain reads. SwiftUI evaluates `isReady`/`hasKey` on
    /// every render; hitting SecItemCopyMatching each time re-triggers macOS keychain
    /// access prompts (especially across ad-hoc-signed rebuilds, where the code
    /// identity changes). The cache guarantees at most ONE keychain read per provider
    /// per launch, and never from a render path after that.
    /// Value semantics: missing entry = not read yet; `.some(nil)` = read, no key.
    private var keyCache: [String: String?] = [:]

    /// The stored key for a provider (nil if none), read through the session cache.
    func key(for kind: ProviderKind) -> String? {
        if let cached = keyCache[kind.rawValue] { return cached }
        let value = Keychain.get(account: kind.rawValue)
        keyCache[kind.rawValue] = value
        return value
    }

    func setKey(_ key: String, for kind: ProviderKind) {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        Keychain.set(trimmed, account: kind.rawValue)
        keyCache[kind.rawValue] = trimmed.isEmpty ? nil : trimmed
        objectWillChange.send()
    }

    func hasKey(for kind: ProviderKind) -> Bool {
        !(key(for: kind) ?? "").isEmpty
    }

    // MARK: Provider

    /// Build the provider for the currently selected settings.
    func makeProvider() -> LLMProvider {
        ProviderFactory.make(kind: kind,
                             baseURL: currentBaseURL,
                             model: currentModel,
                             key: kind.requiresKey ? (key(for: kind) ?? "") : "")
    }

    /// True when the current provider is usable (Ollama always; cloud needs a key + model).
    var isReady: Bool {
        guard !currentModel.isEmpty else { return kind == .ollama }
        return kind.requiresKey ? hasKey(for: kind) : true
    }
}
