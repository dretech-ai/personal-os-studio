import SwiftUI
import Combine

/// Shared application state.
@MainActor
final class AppState: ObservableObject {
    @Published var store: CanonicalStore
    @Published var openclaw: OpenClawService
    @Published var selectedHarness: Harness = Harness.all[0]
    @Published var selectedFile: CanonicalFile?
    @Published var buildResult: BuildResult?
    @Published var selectedWorkspace: OpenClawWorkspace?

    @Published var settings = LLMSettings()
    @Published var openclawSettings: OpenClawSettings
    @Published var showOpenClawNudge = false
    @Published var showOnboarding = false
    @Published var interview: InterviewEngine
    @Published var bootstrap: BootstrapEngine
    /// Set when "Refine with interview" is invoked from the editor; the interview
    /// sheet picks it up on appear and starts a refine run.
    @Published var pendingRefineFile: CanonicalFile?
    /// Set by a browser "+ New <instance>" button; the interview sheet picks it up on
    /// appear and starts a create run against that layer's instance template.
    @Published var pendingCreateTemplate: CanonicalFile?
    /// Eval failures seeding the next refine run (F16) — consumed with pendingRefineFile.
    @Published var pendingRefineEvalNotes: [String] = []

    /// Demo mode (F17): the app is rooted on the fictional Orbit Labs demo OS and all
    /// harness DELIVERY (push, restart, copy, backfeed, connection registration) is
    /// blocked. Train/preview, validation, interviews, and evals stay live — they are
    /// the demo. Persisted so a relaunch mid-demo stays consistent.
    @Published private(set) var demoMode: Bool =
        UserDefaults.standard.bool(forKey: "demo.mode")

    /// Local git awareness for the canonical repo (status/snapshot/history — never remote).
    @Published var git: GitService

    /// Encrypted snapshots of content documents (the PII files git never sees).
    @Published var vault = VaultService()

    /// Validation findings per file id, recomputed whenever the store reloads.
    @Published var validation: [String: [Finding]] = [:]
    private var validationSink: AnyCancellable?

    func findings(for file: CanonicalFile) -> [Finding] {
        validation[file.id] ?? []
    }

    func revalidate() {
        validation = Validator(store: store).validateAll()
        Task {
            await git.refresh()
            await git.updateContentTracking(store: store)
        }
    }

    /// The person authoring their OS — used to fill Identity/User Profile in interviews.
    /// Defaults to the macOS full name; persisted across launches.
    @Published var personName: String {
        didSet { UserDefaults.standard.set(personName, forKey: "person.name") }
    }

    /// The owner email stamped into generated frontmatter (`owner:`) and enterprise
    /// contributions. Persisted; defaults to a neutral placeholder until the user sets
    /// their own — never a hardcoded personal address.
    @Published var ownerEmail: String {
        didSet { UserDefaults.standard.set(ownerEmail, forKey: "owner.email") }
    }
    static let defaultOwnerEmail = "you@example.com"

    init() {
        // Canonical repo resolution: the user's persisted choice, else the current
        // working directory when it's a valid repo (terminal launches), else
        // unresolved — onboarding takes over. No hardcoded machine paths.
        let persisted = UserDefaults.standard.string(forKey: "canonical.root")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let canonical = Self.firstExisting([persisted, cwd].compactMap { $0 }) ?? cwd

        self.store = CanonicalStore(rootURL: canonical)
        self.git = GitService(root: canonical)

        // OpenClaw is never assumed: it starts unconfigured and is wired only from
        // the user's persisted, explicitly-confirmed settings.
        self.openclawSettings = OpenClawSettings()
        self.openclaw = OpenClawService()

        // Owner email: persisted choice, else a neutral placeholder.
        let savedEmail = UserDefaults.standard.string(forKey: "owner.email")
        let email = (savedEmail?.isEmpty == false) ? savedEmail! : Self.defaultOwnerEmail
        self.ownerEmail = email

        // Owner + date used to fill generated frontmatter during interviews.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        let engine = InterviewEngine(ownerEmail: email, today: df.string(from: Date()))
        self.interview = engine
        self.bootstrap = BootstrapEngine(engine: engine)

        // Prefer a saved name; otherwise seed from the macOS full name.
        let savedName = UserDefaults.standard.string(forKey: "person.name")
        self.personName = (savedName?.isEmpty == false) ? savedName! : NSFullUserName()

        // Wire the service from persisted, user-confirmed settings (no-op when unset).
        openclaw.apply(openclawSettings)

        // Re-lint whenever the canonical store reloads (saves, interview writes, …).
        validationSink = store.$filesByLayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.revalidate() }
        self.selectedWorkspace = openclaw.workspaces.first { $0.id.contains("chief-of-staff") }
            ?? openclaw.workspaces.first

        // One-time nudge: if OpenClaw was never configured, present the config sheet on
        // first launch (pre-filled with detected suggestions; nothing wires until
        // confirmed). Decided here — not in a view's onAppear — so it's deterministic.
        if !openclawSettings.isConfigured && !openclawSettings.configPrompted {
            openclawSettings.configPrompted = true
            self.showOpenClawNudge = true
        }

        // No valid canonical repo resolved → onboarding (choose or scaffold one).
        if !store.isValidRoot {
            self.showOnboarding = true
            self.showOpenClawNudge = false   // one sheet at a time; OpenClaw comes after
        }
    }

    /// Re-root the app on a user-chosen canonical repo: persist, reload the store,
    /// re-point git, re-lint. The OpenClaw side is untouched (separate settings).
    func setCanonicalRoot(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: "canonical.root")
        store.setRoot(url)
        git = GitService(root: url)
        selectedFile = nil
        buildResult = nil
        showOnboarding = false
        revalidate()
    }

    // MARK: Demo mode (F17)

    /// Rebuild the demo repo fresh and re-root onto it. Re-entering resets all demo
    /// edits — deterministic demos by construction.
    func enterDemoMode() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        guard let root = try? DemoContent.install(today: df.string(from: Date())) else { return }
        if !demoMode {
            UserDefaults.standard.set(store.rootURL.path, forKey: "demo.previousRoot")
        }
        demoMode = true
        UserDefaults.standard.set(true, forKey: "demo.mode")
        setCanonicalRoot(root)
    }

    /// Restore the real canonical root. The demo repo stays on disk (rebuilt on the
    /// next entry anyway).
    func exitDemoMode() {
        guard demoMode else { return }
        demoMode = false
        UserDefaults.standard.set(false, forKey: "demo.mode")
        if let prev = UserDefaults.standard.string(forKey: "demo.previousRoot") {
            setCanonicalRoot(URL(fileURLWithPath: prev))
        }
    }

    // MARK: Vault

    /// Debounced snapshot of the current canonical repo — call after any save path.
    /// Suspended in demo mode: disposable fictional edits must never enter the real
    /// vault history.
    func vaultAutoSnapshot(reason: String) {
        guard !demoMode else { return }
        vault.autoSnapshot(repo: store.rootURL, reason: reason)
    }

    func vaultManifest(id: String) throws -> PIIVault.Manifest {
        let key = try vault.ensureKey()
        return try PIIVault.manifest(id: id, vaultDir: vault.vaultDir, key: key)
    }

    /// Restore from a snapshot into the current repo (nil paths = everything),
    /// then reload + re-lint so the UI reflects the restored contents.
    func vaultRestore(id: String, paths: [String]?) -> [String] {
        do {
            let key = try vault.ensureKey()
            let log = try PIIVault.restore(id: id, paths: paths, vaultDir: vault.vaultDir,
                                           key: key, into: store.rootURL)
            store.reload()
            revalidate()
            return log
        } catch {
            return ["✗ restore failed: \(error.localizedDescription)"]
        }
    }

    /// Re-apply OpenClaw settings after the user edits them.
    func reconfigureOpenClaw() {
        openclaw.apply(openclawSettings)
        if let sel = selectedWorkspace, !openclaw.workspaces.contains(sel) {
            selectedWorkspace = nil
        }
        if selectedWorkspace == nil { selectedWorkspace = openclaw.workspaces.first }
        if openclawSettings.isConfigured {
            Task { await openclaw.checkHealth() }
        }
    }

    static func firstExisting(_ urls: [URL]) -> URL? {
        urls.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("adapters").path) }
    }

    /// `version:` value from an artifact's provenance HTML comment.
    nonisolated static func provenanceVersion(in text: String) -> String? {
        guard let range = text.range(of: #"version: ([^ |]+)"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("version: ".count))
    }

    /// The canonical file behind a single-source artifact ("Identity ← x.md",
    /// "Skill ← y.md", "Memory ← z.md"); nil for multi-source artifacts.
    private func singleSourceFile(of artifact: BuildArtifact) -> CanonicalFile? {
        let parts = artifact.sourceDescription.components(separatedBy: "← ")
        guard parts.count == 2 else { return nil }
        let filename = parts[1].trimmingCharacters(in: .whitespaces)
        guard !filename.contains(",") else { return nil }   // multi-source
        for layer in Layer.allCases {
            if let f = store.files(layer).first(where: { $0.filename == filename }) { return f }
        }
        return nil
    }

    // MARK: Harness adapters

    /// Registered harness adapters, keyed by `Harness.id`. A harness with a registered
    /// adapter renders the full train/push UI; unregistered ones show Coming Soon.
    private(set) lazy var adapters: [String: HarnessAdapter] = {
        // OpenClaw's delivery reaches the live service for workspace discovery.
        let openclawService = self.openclaw
        let openclawDelivery = DeliveryKind.directory(DirectoryDelivery(
            targetLabel: "Target workspace",
            discoverTargets: {
                openclawService.workspaces.map {
                    PushTargetOption(id: $0.id, displayName: $0.displayName, url: $0.url)
                }
            },
            noTargetGuidance: "OpenClaw isn't configured. Point Studio at your install to enable pushing.",
            postPush: nil,
            healthProbe: nil))   // OpenClaw's health/restart stay in its bespoke panel
        return [
            "openclaw": OpenClawAdapter(delivery: openclawDelivery),
            "hermes": HermesAdapter(),
            "claude-cowork": CoworkAdapter(),
            "codex": CodexAdapter(),
        ]
    }()

    /// Whether a harness has a registered adapter (drives active vs Coming Soon).
    func isActive(_ harness: Harness) -> Bool {
        adapters[harness.id] != nil
    }

    /// Whether the harness's tool is actually present/configured on this machine —
    /// what the sidebar dot shows. Registration alone is NOT availability: a green
    /// dot must never imply an uninstalled tool is running. nil = no adapter.
    func availability(_ harness: Harness) -> (available: Bool, note: String)? {
        guard let adapter = adapters[harness.id] else { return nil }
        switch adapter.delivery {
        case .directory(let delivery):
            if harness.id == "openclaw" {
                guard openclawSettings.isConfigured else {
                    return (false, "Not configured — click the OpenClaw badge to set up")
                }
                let count = openclaw.workspaces.count
                return count > 0 ? (true, "\(count) workspace(s)")
                                 : (false, "Configured, but no workspaces found")
            }
            if let readiness = delivery.readiness {
                let status = readiness()
                return (status.ok, status.message)
            }
            let targets = delivery.discoverTargets()
            return targets.isEmpty ? (false, "Not installed") : (true, targets.first?.displayName ?? "detected")
        case .clipboard(let delivery):
            if let readiness = delivery.readiness {
                let status = readiness()
                return (status.ok, status.message)
            }
            return (true, "Paste-based — no install needed")
        }
    }

    /// Bumped to make observers re-render and re-run the `availability(_:)` closures —
    /// they read the live filesystem, so a tool installed after launch (or a panel
    /// "Re-check") flips the sidebar dot without relaunching.
    @Published private(set) var availabilityTick = 0

    func refreshAvailability() {
        availabilityTick += 1
    }

    func adapter(for harness: Harness) -> HarnessAdapter? {
        adapters[harness.id]
    }

    func rebuild() {
        buildResult = adapter(for: selectedHarness)?.build(from: store)
        // Surface validation findings for the files that went into this build.
        guard buildResult != nil else { return }

        // Staleness: a canonical source changed content-wise but kept the version the
        // deployed artifact was rendered from → the author forgot to bump.
        if let ws = selectedWorkspace, let result = buildResult {
            for artifact in result.artifacts {
                guard let deployed = try? String(contentsOf: ws.url.appendingPathComponent(artifact.relativePath),
                                                 encoding: .utf8),
                      deployed != artifact.contents,
                      let deployedVersion = Self.provenanceVersion(in: deployed),
                      let sourceFile = singleSourceFile(of: artifact),
                      sourceFile.version == deployedVersion
                else { continue }
                buildResult?.warnings.append("\(sourceFile.filename) changed without a version bump (deployed \(artifact.relativePath) was rendered from the same v\(deployedVersion)).")
            }
        }
        for layer in Layer.allCases {
            for file in store.includedFiles(layer) {
                let findings = self.findings(for: file)
                let errors = findings.filter { $0.severity == .error }.count
                let warnings = findings.count - errors
                if errors > 0 || warnings > 0 {
                    let parts = [errors > 0 ? "\(errors) validation error\(errors == 1 ? "" : "s")" : nil,
                                 warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil]
                        .compactMap { $0 }.joined(separator: ", ")
                    buildResult?.warnings.append("\(file.filename): \(parts) — see the editor's findings strip.")
                }
            }
        }
    }
}

@main
struct PersonalOSStudioApp: App {
    @StateObject private var state = AppState()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
        if CommandLine.arguments.contains("--interviewtest") {
            SelfTest.interviewTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--hermestest") {
            SelfTest.hermesTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--coworktest") {
            SelfTest.coworkTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--codextest") {
            SelfTest.codexTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--bootstraptest") {
            SelfTest.bootstrapTest()   // exits via its async task
        }
        if CommandLine.arguments.contains("--providertest") {
            SelfTest.providerTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--refinetest") {
            SelfTest.refineTest()      // exits via its async task
        }
        if CommandLine.arguments.contains("--streamtest") {
            SelfTest.streamTest()      // exits via its async task
        }
        if CommandLine.arguments.contains("--validate") {
            SelfTest.validateRepo()
            exit(0)
        }
        if CommandLine.arguments.contains("--validatetest") {
            SelfTest.validateTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--difftest") {
            SelfTest.diffTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--gittest") {
            SelfTest.gitTest()         // exits via its async task
        }
        if CommandLine.arguments.contains("--scaffoldtest") {
            SelfTest.scaffoldTest()    // exits via its async task
        }
        if CommandLine.arguments.contains("--migratetest") {
            SelfTest.migrateTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--connectionstest") {
            SelfTest.connectionsTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--vaulttest") {
            SelfTest.vaultTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--multidoctest") {
            SelfTest.multiDocTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--backfeedtest") {
            SelfTest.backfeedTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--evaltest") {
            SelfTest.evalTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--demotest") {
            SelfTest.demoTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--enterprisetest") {
            SelfTest.enterpriseTest()
            exit(0)
        }
        if CommandLine.arguments.contains("--eval") {
            SelfTest.evalRun()         // exits via its async task
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                // Floor is set comfortably above the layout's true minimum
                // (sidebar ~250 + three detail panes ~820 ≈ 1070) so the sidebar and
                // all three panes always fit without clipping — and a small restored
                // window frame gets clamped back up to this on launch.
                .frame(minWidth: 1240, minHeight: 720)
                .task {
                    // Never probe an unconfigured gateway.
                    if state.openclawSettings.isConfigured {
                        await state.openclaw.checkHealth()
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
