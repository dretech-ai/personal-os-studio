import Foundation
import Combine

/// Orchestrates the "Bootstrap my OS" wizard: one continuous interview that walks
/// Identity → Role → Domain → Team → Memory index, carrying facts forward between
/// documents (no repeated questions), with per-doc skip and a final batch review/save.
///
/// The per-doc Q&A is delegated to the shared `InterviewEngine` — this type sequences
/// docs, accumulates drafts + carry-forward facts, and owns the wizard lifecycle.
@MainActor
final class BootstrapEngine: ObservableObject {
    enum Phase: Equatable {
        case idle          // wizard not running
        case interviewing  // driving the engine through steps[currentIndex]
        case review        // all docs done — reviewing drafts before batch save
    }

    struct CompletedDoc: Identifiable {
        let id: String            // suggestedRelativePath
        let target: InterviewTarget
        var draft: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var steps: [InterviewTarget] = []
    @Published private(set) var currentIndex = 0
    @Published var completed: [CompletedDoc] = []
    @Published private(set) var skippedCount = 0

    private let engine: InterviewEngine
    /// Per-doc user answers, keyed by doc title — the wizard's carry-forward memory.
    private var facts: [(doc: String, answers: [String])] = []
    private var provider: LLMProvider?
    private var personName = ""
    private var store: CanonicalStore?

    /// Carry-forward blocks are capped so local models keep headroom.
    static let carryForwardCap = 1_500

    init(engine: InterviewEngine) {
        self.engine = engine
    }

    var currentTarget: InterviewTarget? {
        phase == .interviewing && steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
    }
    var progressText: String {
        "Doc \(min(currentIndex + 1, steps.count)) of \(steps.count)"
    }

    // MARK: Step resolution

    /// The wizard's document sequence, resolved from the repo's templates
    /// (missing templates are tolerated by skipping them).
    static func resolveSteps(in store: CanonicalStore) -> [InterviewTarget] {
        let wanted = [
            "identity.template.md",
            "role.template.md",
            "domain.template.md",
            "team.template.md",
            "MEMORY.template.md",
        ]
        let all = InterviewTarget.all(in: store)
        return wanted.compactMap { name in
            all.first { $0.templateURL.lastPathComponent == name }
        }
    }

    /// The wizard is offered when at least two of its docs don't exist yet.
    static func isOffered(in store: CanonicalStore) -> Bool {
        let missing = resolveSteps(in: store).filter {
            !store.fileExists(relativePath: $0.suggestedRelativePath)
        }
        return missing.count >= 2
    }

    // MARK: Lifecycle

    /// Begin the wizard: resolve steps and start the first doc.
    func start(provider: LLMProvider, store: CanonicalStore, personName: String) async {
        self.provider = provider
        self.store = store
        self.personName = personName
        steps = Self.resolveSteps(in: store)
        guard !steps.isEmpty else { return }
        currentIndex = 0
        completed = []
        facts = []
        skippedCount = 0
        phase = .interviewing
        await startCurrentDoc()
    }

    /// Configure + start the engine for the current doc, with carry-forward.
    func startCurrentDoc() async {
        guard let provider, let target = currentTarget else { return }
        let templateText = (try? String(contentsOf: target.templateURL, encoding: .utf8)) ?? ""
        engine.configure(provider: provider, target: target, templateText: templateText,
                         personName: personName, carryForward: carryForwardBlock())
        await engine.start()
    }

    /// Retry the current doc's opening question after a provider error.
    func retryCurrentDoc() async {
        await startCurrentDoc()
    }

    /// Generate the current doc's draft from its transcript, record it, and advance.
    func finishCurrentDoc() async {
        guard let target = currentTarget else { return }
        await engine.generateDraft()
        guard engine.phase == .drafted, !engine.draft.isEmpty else { return }  // error stays visible
        facts.append((doc: target.title, answers: engine.userAnswers))
        completed.append(CompletedDoc(id: target.suggestedRelativePath, target: target, draft: engine.draft))
        await advance()
    }

    /// Skip the current doc (no draft) and advance.
    func skipCurrentDoc() async {
        guard currentTarget != nil else { return }
        skippedCount += 1
        await advance()
    }

    private func advance() async {
        currentIndex += 1
        if currentIndex >= steps.count {
            phase = .review
        } else {
            await startCurrentDoc()
        }
    }

    /// End the interview early, keeping completed drafts for review (or discarding all).
    func exitEarly(keepDrafts: Bool) {
        if keepDrafts && !completed.isEmpty {
            phase = .review
        } else {
            reset()
        }
    }

    /// Save every completed draft into the canonical repo. Returns per-file results.
    func saveAll() -> [String] {
        guard let store else { return ["✗ no canonical store"] }
        var log: [String] = []
        for doc in completed {
            do {
                try store.createFile(relativePath: doc.id, contents: doc.draft)
                log.append("✓ saved \(doc.id)")
            } catch {
                log.append("✗ \(doc.id): \(error.localizedDescription)")
            }
        }
        store.reload()
        return log
    }

    func reset() {
        phase = .idle
        steps = []
        completed = []
        facts = []
        currentIndex = 0
        skippedCount = 0
        engine.reset()
    }

    // MARK: Carry-forward

    /// Test hook: seed facts directly so the carry-forward cap can be verified
    /// headlessly (used by --bootstraptest only).
    func seedFactsForTesting(_ seeded: [(doc: String, answers: [String])]) {
        facts = seeded
    }

    /// Compact summary of everything the user said in earlier docs, capped so the
    /// system prompt stays small (older docs get truncated harder).
    func carryForwardBlock() -> String {
        guard !facts.isEmpty else { return "" }
        var blocks: [String] = []
        for (i, fact) in facts.enumerated() {
            // Most recent docs keep more detail.
            let perDocBudget = i == facts.count - 1 ? 700 : 300
            let joined = fact.answers.joined(separator: " · ")
            let clipped = joined.count > perDocBudget
                ? String(joined.prefix(perDocBudget)) + "…"
                : joined
            blocks.append("- \(fact.doc): \(clipped)")
        }
        var out = blocks.joined(separator: "\n")
        if out.count > Self.carryForwardCap {
            out = String(out.suffix(Self.carryForwardCap))
        }
        return out
    }
}
