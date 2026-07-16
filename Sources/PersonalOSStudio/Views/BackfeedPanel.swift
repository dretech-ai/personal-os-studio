import SwiftUI

/// Harness → canonical review queue: scan a push target for drift, distill each item
/// into a proposal (LLM-gated), and review every proposal as a diff. Accept writes the
/// canonical file behind a vault snapshot; Reject remembers the drift so it is never
/// re-proposed. There is deliberately no "Accept all" — review is the point.
struct BackfeedPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    let harnessID: String
    let harnessName: String
    let target: URL

    @State private var drift: [DriftItem] = []
    @State private var proposals: [Proposal] = []
    @State private var scanning = true
    @State private var distilling = false
    @State private var progress = ""
    @State private var log: [String] = []
    @State private var confirmAccept: Proposal?
    @State private var confirmBaseline = false

    private var dismissedHashes: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "backfeed.dismissed") ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Color.accentColor)
                Text("Harness updates → canonical").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusSection
                    ForEach(proposals) { p in proposalRow(p) }
                    if !log.isEmpty { logSection }
                }
                .padding(12)
            }
        }
        .frame(width: 680, height: 560)
        .task { await runHarvest() }
        .confirmationDialog(
            "Apply to \(confirmAccept?.targetRelativePath ?? "")?",
            isPresented: Binding(get: { confirmAccept != nil },
                                 set: { if !$0 { confirmAccept = nil } }),
            titleVisibility: .visible) {
            Button(confirmAccept?.isNewFile == true
                   ? "Create the canonical file" : "Overwrite the canonical file",
                   role: .destructive) {
                if let p = confirmAccept { accept(p) }
                confirmAccept = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A vault snapshot is taken first when the vault is enabled.")
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusSection: some View {
        if scanning {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning \(target.lastPathComponent)…").font(.caption) }
        } else if drift.isEmpty {
            Label("No changes in \(harnessName) since the last push.", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            HStack(spacing: 6) {
                Label("\(drift.count) change(s) since last push", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                Text("· \(drift.map(\.relativePath).joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            if !state.settings.isReady {
                warnBox("Configure an LLM provider to distill these changes into canonical proposals — the scan works without one, proposals don't.")
            } else if distilling {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).font(.caption) }
            } else if proposals.isEmpty {
                Button {
                    Task { await distill() }
                } label: {
                    Label("Generate proposals", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            // Deterministic, LLM-free escape hatch for noisy first contact (e.g. a
            // harness that ships stock content): baseline everything currently listed.
            if !distilling && proposals.isEmpty {
                Button {
                    confirmBaseline = true
                } label: {
                    Label("Mark all \(drift.count) as reviewed…", systemImage: "checkmark.rectangle.stack")
                        .frame(maxWidth: .infinity)
                }
                .help("Records every listed change as seen (no LLM involved). A file resurfaces only if its content changes again.")
                .confirmationDialog("Dismiss all \(drift.count) change(s) without review?",
                                    isPresented: $confirmBaseline, titleVisibility: .visible) {
                    Button("Dismiss all \(drift.count) unreviewed", role: .destructive) { baselineAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("⚠️ This dismisses everything listed — including any genuine knowledge your agent has learned — and none of it will EVER be proposed again unless the file's content changes. Intended for first contact with a harness's stock content. If this harness has been in use, review the list first: anything real you dismiss here is silently lost to the loop.")
                }
            }
        }
    }

    // MARK: Proposal rows

    private func proposalRow(_ p: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: p.isNewFile ? "doc.badge.plus" : "doc.badge.gearshape")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.targetRelativePath).font(.callout.monospaced())
                    Text("from \(harnessName) · \(p.sourceFile) — \(p.rationale)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if p.isNewFile {
                    Text("new file").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                }
            }
            DisclosureGroup("Review \(p.isNewFile ? "contents" : "diff")") {
                DiffView(old: currentCanonicalText(p), new: p.proposedContents)
                    .frame(maxHeight: 220)
            }
            .font(.caption)
            HStack {
                Spacer()
                Button("Reject") { reject(p) }
                Button("Accept…") { confirmAccept = p }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func currentCanonicalText(_ p: Proposal) -> String {
        (try? String(contentsOf: state.store.rootURL.appendingPathComponent(p.targetRelativePath),
                     encoding: .utf8)) ?? ""
    }

    // MARK: Actions

    private func runHarvest() async {
        scanning = true
        let manifest = PushLedger.standard.manifest(harness: harnessID, target: target)
        let firstPush = PushLedger.standard.firstPush(harness: harnessID, target: target)
        let result = HarvestScanner.scan(target: target, manifest: manifest, firstPush: firstPush)
        drift = result.items.filter { !dismissedHashes.contains($0.contentHash) }
        if result.preexistingSkipped > 0 {
            log.append("· \(result.preexistingSkipped) pre-existing file(s) skipped (created before Studio's first push — vendor/stock content, not drift)")
        }
        let suppressed = result.items.count - drift.count
        if suppressed > 0 { log.append("· \(suppressed) previously reviewed change(s) hidden") }
        if manifest.isEmpty { log.append("· no push ledger for this target yet — push once, then changes become detectable") }
        scanning = false
    }

    /// Bulk baseline: dismiss every currently listed drift item by content hash.
    private func baselineAll() {
        var dismissed = UserDefaults.standard.stringArray(forKey: "backfeed.dismissed") ?? []
        dismissed.append(contentsOf: drift.map(\.contentHash))
        UserDefaults.standard.set(Array(dismissed.suffix(5000)), forKey: "backfeed.dismissed")
        log.append("· marked \(drift.count) change(s) as reviewed — only future changes will surface")
        drift = []
        proposals = []
    }

    private func distill() async {
        distilling = true
        let provider = state.settings.makeProvider()
        var out: [Proposal] = []
        for (i, item) in drift.enumerated() {
            progress = "Distilling \(item.relativePath) (\(i + 1)/\(drift.count))…"
            let (system, user) = ProposalEngine.prompt(
                item: item, harnessName: harnessName, store: state.store,
                ownerEmail: state.ownerEmail, today: Self.today())
            do {
                let raw = try await provider.complete(
                    system: system, messages: [ChatMessage(role: .user, content: user)])
                if let p = ProposalEngine.finalize(item: item, harness: harnessID,
                                                   rawResponse: raw,
                                                   canonicalRoot: state.store.rootURL,
                                                   today: Self.today()) {
                    out.append(p)
                } else {
                    log.append("✗ \(item.relativePath): proposal failed guardrails/validation — dropped")
                }
            } catch {
                log.append("✗ \(item.relativePath): \((error as? LLMError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        proposals = out
        distilling = false
    }

    private func accept(_ p: Proposal) {
        if state.vault.enabled {
            guard state.vault.snapshotNow(repo: state.store.rootURL, reason: "backfeed accept") else {
                log.append("✗ vault snapshot failed — nothing written")
                return
            }
        }
        do {
            _ = try state.store.createFile(relativePath: p.targetRelativePath,
                                           contents: p.proposedContents)
            state.store.reload()
            state.revalidate()
            log.append("✓ wrote \(p.targetRelativePath)")
            proposals.removeAll { $0.id == p.id }
            drift.removeAll { $0.contentHash == p.driftHash }
        } catch {
            log.append("✗ write failed: \(error.localizedDescription)")
        }
    }

    private func reject(_ p: Proposal) {
        var dismissed = UserDefaults.standard.stringArray(forKey: "backfeed.dismissed") ?? []
        dismissed.append(p.driftHash)
        UserDefaults.standard.set(Array(dismissed.suffix(5000)), forKey: "backfeed.dismissed")
        proposals.removeAll { $0.id == p.id }
        drift.removeAll { $0.contentHash == p.driftHash }
        log.append("· rejected \(p.targetRelativePath) — won't be re-proposed")
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
