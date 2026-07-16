import SwiftUI
import AppKit

/// The enterprise sharing loop. **Client mode:** AI-vetted candidates from the local
/// canonical repo are pushed to the shared repo's `suggested/` stage (or skipped), and
/// admin-allowed `catalog/` content is pulled into the local OS. **Admin mode:** a
/// distinct curation experience — review `suggested/` and flag items allowed or
/// disallowed. The whole feature is AI-gated: without a provider it shows guidance.
struct EnterprisePanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    enum Mode: String, CaseIterable { case client = "Client", admin = "Admin" }

    struct Candidate: Identifiable {
        let file: CanonicalFile
        let contents: String
        let contentHash: String
        var vet: EnterpriseVet.Result?
        var vetting = false
        var id: String { file.id }
    }

    @State private var mode: Mode =
        UserDefaults.standard.bool(forKey: "enterprise.adminMode") ? .admin : .client
    @State private var repo: EnterpriseRepo?
    @State private var candidates: [Candidate] = []
    @State private var catalog: [EnterpriseItem] = []
    @State private var suggested: [EnterpriseItem] = []
    @State private var disallowed: [EnterpriseItem] = []
    @State private var log: [String] = []
    @State private var disallowTarget: EnterpriseItem?
    @State private var disallowNote = ""
    @State private var confirmPull: EnterpriseItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !state.settings.isReady {
                        warnBox("The enterprise library is an AI-enabled feature — configure an LLM provider to vet contributions and use it. (Provider button in the toolbar.)")
                    } else if repo == nil {
                        configSection
                    } else {
                        repoBar
                        if mode == .client {
                            contributeSection
                            pullSection
                        } else {
                            adminSection
                        }
                    }
                    if !log.isEmpty { logSection }
                }
                .padding(12)
            }
        }
        .frame(width: 720, height: 600)
        .onAppear(perform: reload)
        .sheet(item: $disallowTarget) { item in disallowSheet(item) }
        .confirmationDialog("Pull \"\(confirmPull?.title ?? "")\" into your OS?",
                            isPresented: Binding(get: { confirmPull != nil },
                                                 set: { if !$0 { confirmPull = nil } }),
                            titleVisibility: .visible) {
            Button("Pull into \(confirmPull.map { "\($0.layer.rawValue)/\($0.filename)" } ?? "")") {
                if let item = confirmPull { pull(item) }
                confirmPull = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Writes the document into your canonical repo (validation-gated; vault snapshot first).")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: mode == .admin ? "checkmark.shield" : "building.2")
                .foregroundStyle(mode == .admin ? Color.purple : Color.accentColor)
            Text(mode == .admin ? "Enterprise · Admin" : "Enterprise library")
                .font(.headline)
            if mode == .admin {
                Text("curation mode").font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.purple.opacity(0.18)))
            }
            Spacer()
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .onChange(of: mode) { _, m in
                UserDefaults.standard.set(m == .admin, forKey: "enterprise.adminMode")
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(mode == .admin ? Color.purple.opacity(0.08) : Color.clear)
    }

    // MARK: Configuration

    /// The active repo, always visible and switchable — admins routinely point at
    /// different repos (per-org, or a staging clone vs the live one).
    private var repoBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(mode == .admin ? Color.purple : Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(repo?.root.lastPathComponent ?? "").font(.caption.weight(.medium))
                Text(repo?.root.path ?? "")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Change repo…") { chooseRepo() }
                .controlSize(.small)
                .help("Point at a different enterprise repo (an empty folder will be initialized)")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((mode == .admin ? Color.purple : Color.secondary).opacity(0.07)))
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            warnBox("No enterprise repo configured. Point Studio at your organization's local clone — Studio reads and writes the clone only; syncing with the remote stays a git action.")
            HStack {
                Button("Choose enterprise repo…") { chooseRepo() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this repo"
        panel.message = "Choose the enterprise Agent OS repo (contains suggested/ and catalog/). An empty folder will be initialized."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let candidate = EnterpriseRepo(root: url)
        if !candidate.isValid {
            do { try EnterpriseRepo.initialize(at: url) } catch {
                log.append("✗ could not initialize: \(error.localizedDescription)")
                return
            }
            log.append("✓ initialized enterprise repo structure at \(url.lastPathComponent)")
        }
        UserDefaults.standard.set(url.path, forKey: EnterpriseRepo.pathKey)
        reload()
    }

    // MARK: Client · contribute

    private var contributeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Contribute — candidates from your OS (\(candidates.count))")
            if candidates.isEmpty {
                Text("No candidates: Enterprise/Public content that isn't already in the enterprise repo (and wasn't skipped) appears here.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(candidates) { candidate in candidateRow(candidate) }
        }
    }

    private func candidateRow(_ candidate: Candidate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: candidate.file.layer.symbol).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.file.title).font(.callout)
                    Text("\(candidate.file.layer.rawValue)/\(candidate.file.filename)")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                DesignationTag(designation: candidate.file.designation)
                Spacer()
                if candidate.vetting {
                    ProgressView().controlSize(.small)
                } else if candidate.vet == nil {
                    Button("AI vet") { Task { await vet(candidate) } }
                        .controlSize(.small)
                }
            }
            if let vet = candidate.vet {
                HStack(spacing: 6) {
                    Image(systemName: vet.share ? "checkmark.seal.fill" : "hand.raised.fill")
                        .foregroundStyle(vet.share ? .green : .orange)
                        .font(.caption)
                    Text(vet.share ? vet.summary : "Held: \(vet.concerns)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button("Skip") { skip(candidate) }
                    Button("Push to suggested…") { push(candidate) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!vet.share)
                        .help(vet.share ? "Contribute to the enterprise repo for admin review"
                                        : "The AI vet held this — resolve the concern or Skip")
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: Client · pull

    private var pullSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            let pullable = catalog.filter { !existsLocally($0) }
            let owned = catalog.count - pullable.count
            sectionLabel("Pull — allowed catalog (\(pullable.count) new)")
            if owned > 0 {
                Text("· \(owned) catalog item(s) already in your OS")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if pullable.isEmpty && owned == 0 {
                Text("The catalog is empty — contributions appear here once an admin allows them.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(pullable) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: item.layer.symbol).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.callout)
                            Text("by \(item.contributedBy) · \(item.contributedOn)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        DesignationTag(designation: item.designation)
                        Spacer()
                        Button("Pull…") { confirmPull = item }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    DisclosureGroup("Preview") {
                        ScrollView {
                            Text(item.contents)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 160)
                    }
                    .font(.caption2)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
        }
    }

    // MARK: Admin

    private var adminSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Suggested — awaiting review (\(suggested.count))")
                if suggested.isEmpty {
                    Text("Nothing pending. Client contributions land here.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(suggested) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: item.layer.symbol).foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.callout)
                                Text("by \(item.contributedBy) · \(item.contributedOn) · \(item.layer.rawValue)/\(item.filename)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            DesignationTag(designation: item.designation)
                            Spacer()
                            Button("Disallow…") { disallowNote = ""; disallowTarget = item }
                            Button("Allow") { allow(item) }
                                .buttonStyle(.borderedProminent).tint(.green)
                        }
                        DisclosureGroup("Review contents") {
                            ScrollView {
                                Text(item.contents)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                        }
                        .font(.caption2)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.06)))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Catalog (\(catalog.count)) · Disallowed (\(disallowed.count))")
                ForEach(catalog) { item in
                    Label("\(item.title) — by \(item.contributedBy)", systemImage: "checkmark.seal")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(disallowed) { item in
                    Label("\(item.title) — \(item.moderationNote)", systemImage: "nosign")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
    }

    private func disallowSheet(_ item: EnterpriseItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Disallow \"\(item.title)\"").font(.headline)
            Text("The item moves to disallowed/ and stays in the audit trail. The note is required — it tells the contributor (and future admins) why.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Moderation note (required)", text: $disallowNote)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { disallowTarget = nil }
                Button("Disallow", role: .destructive) {
                    disallow(item, note: disallowNote)
                    disallowTarget = nil
                }
                .disabled(disallowNote.trimmingCharacters(in: .whitespaces).count < 8)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: Actions

    private func reload() {
        repo = EnterpriseRepo.configured
        guard let repo else { candidates = []; catalog = []; suggested = []; disallowed = []; return }
        catalog = repo.items(in: .catalog)
        suggested = repo.items(in: .suggested)
        disallowed = repo.items(in: .disallowed)

        let skipped = EnterpriseRepo.skippedHashes()
        var found: [Candidate] = []
        for layer in EnterpriseRepo.sharedLayers {
            for file in state.store.files(layer)
            where !file.isTemplate && !file.isExample
                && (file.designation == .enterprise || file.designation == .pub) {
                let contents = state.store.read(file)
                let hash = PushLedger.sha256(contents)
                guard !skipped.contains(hash) else { continue }
                let name = Frontmatter.split(contents).0["name"]
                    ?? (file.filename as NSString).deletingPathExtension
                guard repo.stage(ofName: name, layer: layer) == nil else { continue }
                found.append(Candidate(file: file, contents: contents, contentHash: hash))
            }
        }
        candidates = found
    }

    private func vet(_ candidate: Candidate) async {
        guard let idx = candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
        candidates[idx].vetting = true
        let result = await EnterpriseVet.vet(
            title: candidate.file.title,
            designation: candidate.file.designation.label,
            contents: candidate.contents,
            provider: state.settings.makeProvider())
        if let idx = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[idx].vet = result
            candidates[idx].vetting = false
        }
    }

    private func push(_ candidate: Candidate) {
        guard let repo else { return }
        do {
            _ = try repo.contribute(contents: candidate.contents,
                                    layer: candidate.file.layer,
                                    filename: candidate.file.filename,
                                    contributedBy: state.ownerEmail,
                                    today: Self.today())
            log.append("✓ pushed \(candidate.file.filename) to suggested/ — awaiting admin review")
            reload()
        } catch {
            log.append("✗ push failed: \(error.localizedDescription)")
        }
    }

    private func skip(_ candidate: Candidate) {
        EnterpriseRepo.recordSkip(hash: candidate.contentHash)
        log.append("· skipped \(candidate.file.filename) — won't be proposed again unless it changes")
        reload()
    }

    private func allow(_ item: EnterpriseItem) {
        guard let repo else { return }
        do {
            _ = try repo.allow(item)
            log.append("✓ allowed \(item.filename) → catalog/")
            reload()
        } catch { log.append("✗ allow failed: \(error.localizedDescription)") }
    }

    private func disallow(_ item: EnterpriseItem, note: String) {
        guard let repo else { return }
        do {
            _ = try repo.disallow(item, note: note)
            log.append("· disallowed \(item.filename) — kept in the audit trail")
            reload()
        } catch { log.append("✗ disallow failed: \(error.localizedDescription)") }
    }

    private func existsLocally(_ item: EnterpriseItem) -> Bool {
        state.store.files(item.layer).contains { file in
            !file.isTemplate && !file.isExample
                && (Frontmatter.split(state.store.read(file)).0["name"] == item.name
                    || file.filename == item.filename)
        }
    }

    private func pull(_ item: EnterpriseItem) {
        let target = "\(item.layer.rawValue)/\(item.filename)"
        let errors = ProposalEngine.validationErrors(contents: item.contents,
                                                     target: target, store: state.store)
        guard errors.isEmpty else {
            log.append("✗ pull blocked — \(item.filename) fails validation: \(errors.map(\.rule).joined(separator: ", "))")
            return
        }
        if state.vault.enabled {
            guard state.vault.snapshotNow(repo: state.store.rootURL, reason: "enterprise pull") else {
                log.append("✗ vault snapshot failed — nothing written")
                return
            }
        }
        do {
            _ = try state.store.createFile(relativePath: target, contents: item.contents)
            state.store.reload()
            state.revalidate()
            log.append("✓ pulled \(target) into your OS")
            reload()
        } catch {
            log.append("✗ pull failed: \(error.localizedDescription)")
        }
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
