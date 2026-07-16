import SwiftUI

/// Run the eval suite against a harness's compiled artifacts, review verdicts with
/// history, generate case drafts from the spec, and send failures into the refine
/// interview — the loop's measuring instrument.
struct EvalsPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    let harnessID: String
    let harnessName: String

    struct RowResult: Identifiable {
        let id = UUID()
        let evalCase: EvalCase
        let verdict: EvalJudge.Verdict
    }

    @State private var cases: [EvalCase] = []
    @State private var excludedCount = 0
    @State private var malformedCount = 0
    @State private var running = false
    @State private var progress = ""
    @State private var results: [RowResult] = []
    @State private var regressions: [String] = []
    @State private var history: [EvalStore.RunRecord] = []
    @State private var drafts: [EvalDraft] = []
    @State private var generating = false
    @State private var confirmOverwrite: EvalDraft?
    @State private var showRefine = false
    @State private var log: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "gauge.with.needle").foregroundStyle(Color.accentColor)
                Text("Evals → \(harnessName)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    suiteSection
                    if !results.isEmpty { resultsSection }
                    generateSection
                    if !log.isEmpty { logSection }
                }
                .padding(12)
            }
        }
        .frame(width: 700, height: 600)
        .onAppear(perform: reload)
        .sheet(isPresented: $showRefine, onDismiss: { reload() }) {
            InterviewView(engine: state.interview, settings: state.settings)
                .environmentObject(state)
        }
    }

    // MARK: Suite

    @ViewBuilder
    private var suiteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Suite (\(cases.count) case\(cases.count == 1 ? "" : "s"))")
            if cases.isEmpty && drafts.isEmpty {
                Text("No eval cases yet. Generate drafts from your spec below — skills' Test Plans, memory recall, and identity behavior become measurable cases in evals/.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if excludedCount > 0 {
                Text("· \(excludedCount) case(s) skipped — their source doc isn't included in this build")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if malformedCount > 0 {
                Label("\(malformedCount) malformed case file(s) in evals/ — run `--validate` for details",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if !history.isEmpty {
                HStack(spacing: 6) {
                    Text("History:").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(Array(history.prefix(6).enumerated()), id: \.offset) { _, run in
                        Text("\(run.passCount)/\(run.results.count)")
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(
                                run.passCount == run.results.count
                                    ? Color.green.opacity(0.18) : Color.orange.opacity(0.18)))
                            .help(run.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }
            if state.buildResult == nil {
                warnBox("Train first — evals run against the compiled artifacts, so this harness needs a build.")
            } else if !state.settings.isReady {
                warnBox("Configure an LLM provider — the subject runs against your model (local Ollama works offline).")
            } else if !cases.isEmpty {
                if running {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).font(.caption) }
                } else {
                    Button {
                        Task { await runSuite() }
                    } label: {
                        Label("Run \(cases.count) case(s)", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let passed = results.filter { $0.verdict.kind == .pass }.count
            HStack {
                sectionLabel("Results — \(passed)/\(results.count) passed")
                Spacer()
                if !regressions.isEmpty {
                    Label("\(regressions.count) regression(s) vs previous run",
                          systemImage: "arrow.down.right.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            ForEach(results) { row in resultRow(row) }
        }
    }

    private func resultRow(_ row: RowResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                verdictBadge(row.verdict)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.evalCase.title).font(.callout)
                    Text("\(row.evalCase.source)\(row.evalCase.sourceVersion.isEmpty ? "" : " · v\(row.evalCase.sourceVersion)") — \(row.verdict.reason)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if row.verdict.kind != .pass,
                   state.store.file(atRelativePath: row.evalCase.source) != nil {
                    Button("Refine…") { refineFromFailure(row) }
                        .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func verdictBadge(_ v: EvalJudge.Verdict) -> some View {
        let (color, symbol): (Color, String) = switch v.kind {
        case .pass: (.green, "checkmark.circle.fill")
        case .fail: (.red, "xmark.circle.fill")
        case .partial: (.orange, "minus.circle.fill")
        }
        return Label(v.kind.rawValue + (v.deterministic ? " ✓det" : ""), systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 84, alignment: .leading)
    }

    // MARK: Generation

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Generate cases from the spec")
            HStack {
                Button {
                    generateDeterministic()
                } label: {
                    Label("From Test Plans & memory", systemImage: "list.bullet.clipboard")
                }
                Button {
                    Task { await generateIdentity() }
                } label: {
                    Label(generating ? "Drafting…" : "From identity (LLM)", systemImage: "wand.and.stars")
                }
                .disabled(generating || !state.settings.isReady)
            }
            .controlSize(.small)
            ForEach(drafts) { draft in draftRow(draft) }
        }
    }

    private func draftRow(_ draft: EvalDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.plus").foregroundStyle(.secondary)
                Text("evals/\(draft.filename)").font(.caption.monospaced())
                Text(draft.origin).font(.caption2).foregroundStyle(.tertiary)
                if draft.exists {
                    Text("exists — will overwrite").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Button("Discard") { drafts.removeAll { $0.id == draft.id } }
                    .controlSize(.mini)
                Button("Save") {
                    if draft.exists { confirmOverwrite = draft } else { save(draft) }
                }
                .controlSize(.mini)
                .buttonStyle(.borderedProminent)
            }
            DisclosureGroup("Preview\(draft.exists ? " (diff vs existing)" : "")") {
                if draft.exists {
                    DiffView(old: existingText(draft), new: draft.contents)
                        .frame(maxHeight: 180)
                } else {
                    ScrollView {
                        Text(draft.contents)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }
            .font(.caption2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .confirmationDialog("Overwrite evals/\(confirmOverwrite?.filename ?? "")?",
                            isPresented: Binding(get: { confirmOverwrite?.id == draft.id },
                                                 set: { if !$0 { confirmOverwrite = nil } }),
                            titleVisibility: .visible) {
            Button("Overwrite (hand-edits are lost)", role: .destructive) {
                if let d = confirmOverwrite { save(d) }
                confirmOverwrite = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Actions

    private func reload() {
        let root = state.store.rootURL
        let all = EvalCase.loadAll(root: root)
        var included: [EvalCase] = []
        var excluded = 0
        for c in all {
            if let src = state.store.file(atRelativePath: c.source), src.include {
                included.append(c)
            } else {
                excluded += 1
            }
        }
        cases = included
        excludedCount = excluded
        malformedCount = Validator(store: state.store).evalFindings().count
        history = EvalStore.standard.history(harness: harnessID)
    }

    private func runSuite() async {
        guard let build = state.buildResult else { return }
        running = true
        results = []
        regressions = []
        let provider = state.settings.makeProvider()
        let context = EvalRunner.primedContext(harnessID: harnessID,
                                               harnessName: harnessName, result: build)
        var rows: [RowResult] = []
        for (i, evalCase) in cases.enumerated() {
            progress = "Running \(evalCase.name) (\(i + 1)/\(cases.count))…"
            do {
                let transcript = try await EvalRunner.runSubject(
                    case: evalCase, context: context, provider: provider)
                let verdict = await EvalJudge.score(case: evalCase, transcript: transcript,
                                                    provider: provider)
                rows.append(RowResult(evalCase: evalCase, verdict: verdict))
            } catch {
                rows.append(RowResult(evalCase: evalCase, verdict: EvalJudge.Verdict(
                    kind: .partial,
                    reason: "subject error: \((error as? LLMError)?.errorDescription ?? error.localizedDescription)",
                    deterministic: false)))
            }
        }
        results = rows

        let record = EvalStore.RunRecord(
            date: Date(), harness: harnessID,
            results: rows.map {
                EvalStore.CaseResult(name: $0.evalCase.name,
                                     verdict: $0.verdict.kind.rawValue,
                                     reason: $0.verdict.reason,
                                     source: $0.evalCase.source)
            },
            sourceVersions: context.sourceVersions)
        let previous = EvalStore.standard.history(harness: harnessID).first
        EvalStore.standard.append(record)
        if let previous {
            regressions = EvalStore.regressions(latest: record, previous: previous)
        }
        history = EvalStore.standard.history(harness: harnessID)
        running = false
    }

    private func refineFromFailure(_ row: RowResult) {
        guard let file = state.store.file(atRelativePath: row.evalCase.source) else { return }
        state.pendingRefineEvalNotes =
            ["\"\(row.evalCase.title)\" (\(row.verdict.kind.rawValue)): \(row.verdict.reason). " +
             "Prompt was: \(row.evalCase.prompt.prefix(300)). Expected: \(row.evalCase.expectation.prefix(300))"]
        state.pendingRefineFile = file
        showRefine = true
    }

    private func generateDeterministic() {
        let new = EvalGenerator.deterministicDrafts(
            store: state.store, ownerEmail: state.ownerEmail, today: Self.today())
        merge(new)
        if new.isEmpty { log.append("· nothing to seed — needs included skills with Test Plans or memory entries") }
    }

    private func generateIdentity() async {
        guard let identity = state.store.includedFiles(.identity)
            .first(where: { !$0.isTemplate && !$0.isExample }) else {
            log.append("· no identity document included in the build")
            return
        }
        generating = true
        let text = state.store.read(identity)
        let rel = identity.url.resolvingSymlinksInPath().path
            .replacingOccurrences(of: state.store.rootURL.resolvingSymlinksInPath().path + "/", with: "")
        let (system, user) = EvalGenerator.identityPrompt(
            identityText: text, ownerEmail: state.ownerEmail,
            today: Self.today(), sourcePath: rel,
            sourceVersion: Frontmatter.split(text).0["version"] ?? "")
        do {
            let raw = try await state.settings.makeProvider().complete(
                system: system, messages: [ChatMessage(role: .user, content: user)])
            let parsed = EvalGenerator.parseIdentityDrafts(raw, root: state.store.rootURL)
            merge(parsed)
            if parsed.isEmpty { log.append("✗ identity drafting produced no valid cases — try again or a stronger model") }
        } catch {
            log.append("✗ identity drafting failed: \((error as? LLMError)?.errorDescription ?? error.localizedDescription)")
        }
        generating = false
    }

    private func merge(_ new: [EvalDraft]) {
        for draft in new where !drafts.contains(where: { $0.filename == draft.filename }) {
            drafts.append(draft)
        }
    }

    private func save(_ draft: EvalDraft) {
        do {
            _ = try state.store.createFile(relativePath: "\(EvalCase.dirName)/\(draft.filename)",
                                           contents: draft.contents)
            drafts.removeAll { $0.id == draft.id }
            log.append("✓ saved evals/\(draft.filename)")
            state.vaultAutoSnapshot(reason: "eval case saved")
            reload()
        } catch {
            log.append("✗ save failed: \(error.localizedDescription)")
        }
    }

    private func existingText(_ draft: EvalDraft) -> String {
        (try? String(contentsOf: state.store.rootURL
            .appendingPathComponent("\(EvalCase.dirName)/\(draft.filename)"), encoding: .utf8)) ?? ""
    }

    // MARK: Bits

    private static func today() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        return df.string(from: Date())
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(log, id: \.self) { line in
                Text(line).font(.caption2.monospaced())
                    .foregroundStyle(line.hasPrefix("✗") ? .red : .secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func warnBox(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            Text(s).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }
}
