import SwiftUI
import AppKit

/// Right pane for directory-delivered harnesses that don't need a bespoke panel
/// (Hermes, Codex, …): train, preview artifacts, pick a target from the delivery
/// descriptor, push via DirectoryPusher (+ the adapter's post-push action), with an
/// optional health probe. OpenClaw keeps its own richer panel.
struct GenericDirectoryPanel: View {
    @EnvironmentObject var state: AppState
    let delivery: DirectoryDelivery

    @State private var targets: [PushTargetOption] = []
    @State private var selectedTarget: PushTargetOption?
    @State private var selectedArtifact: BuildArtifact?
    @State private var backup = true
    @State private var confirmPush = false
    @State private var pushLog: [String] = []
    @State private var pushing = false
    @State private var probeOK: Bool?
    @State private var customTargetError: String?
    @State private var showBackfeed = false
    @State private var showEvals = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: state.selectedHarness.symbol).foregroundStyle(Color.accentColor)
                Text("Train → \(state.selectedHarness.name)").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    targetSection
                    trainSection
                    backfeedSection
                    if let result = state.buildResult {
                        artifactsSection(result)
                        warningsSection(result)
                        pushSection(result)
                    }
                    if !pushLog.isEmpty { pushLogSection }
                }
                .padding(12)
            }
        }
        .sheet(item: $selectedArtifact) { art in
            ArtifactPreviewSheet(artifact: art)
        }
        .confirmationDialog("Push to \(state.selectedHarness.name)?", isPresented: $confirmPush, titleVisibility: .visible) {
            Button("Write \(state.buildResult?.artifacts.count ?? 0) file(s) to \(selectedTarget?.displayName ?? "?")", role: .destructive) {
                Task { await doPush() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This overwrites files in \(selectedTarget?.url.path ?? ""). \(backup ? "Existing files are backed up (.bak-studio)." : "No backups will be made.")")
        }
        .onAppear(perform: refreshTargets)
        .task { await probeHealth() }
        .sheet(isPresented: $showBackfeed) {
            if let target = effectiveTarget {
                BackfeedPanel(harnessID: state.selectedHarness.id,
                              harnessName: state.selectedHarness.name,
                              target: target.url)
                    .environmentObject(state)
            }
        }
        .sheet(isPresented: $showEvals) {
            EvalsPanel(harnessID: state.selectedHarness.id,
                       harnessName: state.selectedHarness.name)
                .environmentObject(state)
        }
    }

    // MARK: Backfeed (F15) + Evals (F16)

    @ViewBuilder
    private var backfeedSection: some View {
        if effectiveTarget != nil && !state.demoMode {
            Button {
                showBackfeed = true
            } label: {
                Label("Check for harness updates…", systemImage: "arrow.uturn.backward.circle")
                    .frame(maxWidth: .infinity)
            }
            .help("Detect what changed in the target since the last push and fold it back into canonical as reviewed proposals")
        }
        if state.buildResult != nil {
            Button {
                showEvals = true
            } label: {
                Label("Evaluate against spec…", systemImage: "gauge.with.needle")
                    .frame(maxWidth: .infinity)
            }
            .help("Run the eval suite against this harness's compiled artifacts and score behavior against the spec")
        }
    }

    // MARK: Target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("1 · \(delivery.targetLabel)")
            if let readiness = delivery.readiness {
                let status = readiness()
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.ok ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(status.message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if targets.isEmpty {
                warnBox(delivery.noTargetGuidance)
                HStack {
                    if let custom = delivery.customTarget {
                        Button(custom.buttonLabel) { chooseCustomTarget(custom) }
                    }
                    Button("Re-check") { refreshTargets() }
                }
                .controlSize(.small)
                if let err = customTargetError {
                    Label(err, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            } else {
                if targets.count == 1 {
                    Label(targets[0].displayName, systemImage: "folder.fill")
                        .font(.callout)
                } else {
                    Picker("", selection: Binding(
                        get: { selectedTarget ?? targets.first! },
                        set: { selectedTarget = $0 })) {
                        ForEach(targets) { t in Text(t.displayName).tag(t) }
                    }
                    .labelsHidden()
                }
                HStack {
                    Text(selectedTarget?.url.path ?? targets.first?.url.path ?? "")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    if let custom = delivery.customTarget {
                        Button(custom.buttonLabel) { chooseCustomTarget(custom) }
                            .controlSize(.mini)
                    }
                }
                if let err = customTargetError {
                    Label(err, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            if let probe = delivery.healthProbe {
                HStack(spacing: 6) {
                    Circle()
                        .fill(probeOK == true ? Color.green : (probeOK == false ? .red : .yellow))
                        .frame(width: 8, height: 8)
                    Text("\(probe.label) \(probeOK == true ? "reachable" : probeOK == false ? "not running" : "…")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // Mirror OpenClaw's "Control UI" link once the probe confirms it's up.
                    if probeOK == true, let url = URL(string: probe.url) {
                        Link("Open", destination: url).font(.caption)
                    }
                    Button { Task { await probeHealth() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Train

    private var trainSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("2 · Train (apply adapter)")
            Button {
                state.rebuild()
                selectedArtifact = nil
                pushLog = []
            } label: {
                Label("Train from canonical", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Artifacts / warnings

    private func artifactsSection(_ result: BuildResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("3 · Generated files")
                Spacer()
                DesignationTag(designation: result.effectiveDesignation)
            }
            if result.artifacts.isEmpty {
                Text("Nothing generated.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(result.artifacts) { art in
                Button { selectedArtifact = art } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(art.relativePath).font(.callout.monospaced())
                            Text(art.sourceDescription).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(art.byteCount)B").font(.caption2).foregroundStyle(.tertiary)
                        Image(systemName: "eye").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func warningsSection(_ result: BuildResult) -> some View {
        Group {
            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(result.warnings, id: \.self) { w in warnBox(w) }
                }
            }
        }
    }

    // MARK: Push

    private func pushSection(_ result: BuildResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("4 · Push")
            if state.demoMode {
                warnBox("Demo mode — harness delivery is disabled. Previews above show exactly what WOULD be written.")
            }
            Toggle("Back up existing files (.bak-studio)", isOn: $backup)
                .font(.caption)
            if result.effectiveDesignation == .pii {
                warnBox("Output is PII. It is written only to the local target — never commit that tree.")
            }
            Button {
                confirmPush = true
            } label: {
                Label(pushing ? "Pushing…" : "Push to \(effectiveTarget?.displayName ?? "target")",
                      systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(pushing || result.artifacts.isEmpty || effectiveTarget == nil || state.demoMode)
        }
    }

    private var pushLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Push log")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(pushLog, id: \.self) { line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(line.hasPrefix("✗") ? .red : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
        }
    }

    // MARK: Actions

    private var effectiveTarget: PushTargetOption? { selectedTarget ?? targets.first }

    private func refreshTargets() {
        targets = delivery.discoverTargets()
        if let sel = selectedTarget, !targets.contains(sel) { selectedTarget = nil }
        if selectedTarget == nil { selectedTarget = targets.first }
        // The sidebar availability dot reads the same filesystem state — re-evaluate
        // it too, so a successful Re-check turns the dot green immediately.
        state.refreshAvailability()
    }

    private func chooseCustomTarget(_ custom: CustomTargetSpec) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = custom.panelMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let error = custom.validate(url) {
            customTargetError = error
            return
        }
        customTargetError = nil
        UserDefaults.standard.set(url.path, forKey: custom.defaultsKey)
        refreshTargets()
    }

    private func doPush() async {
        guard let result = state.buildResult, let target = effectiveTarget else { return }
        pushing = true

        var log: [String]
        if let partition = delivery.partition {
            // Split artifacts by destination: the selected target vs fixed dirs.
            var targetArtifacts: [BuildArtifact] = []
            var fixedGroups: [(url: URL, label: String, artifacts: [BuildArtifact])] = []
            for artifact in result.artifacts {
                switch partition(artifact) {
                case .target:
                    targetArtifacts.append(artifact)
                case .fixed(let url, let label):
                    if let i = fixedGroups.firstIndex(where: { $0.url == url }) {
                        fixedGroups[i].artifacts.append(artifact)
                    } else {
                        fixedGroups.append((url, label, [artifact]))
                    }
                }
            }
            var targetResult = BuildResult(); targetResult.artifacts = targetArtifacts
            log = DirectoryPusher.push(targetResult, into: target.url, backup: backup)
            PushLedger.standard.record(harness: state.selectedHarness.id,
                                       target: target.url, artifacts: targetArtifacts)
            for group in fixedGroups {
                var groupResult = BuildResult(); groupResult.artifacts = group.artifacts
                log.append("→ \(group.label):")
                log += DirectoryPusher.push(groupResult, into: group.url, backup: backup)
                PushLedger.standard.record(harness: state.selectedHarness.id,
                                           target: group.url, artifacts: group.artifacts)
            }
        } else {
            log = DirectoryPusher.push(result, into: target.url, backup: backup)
            PushLedger.standard.record(harness: state.selectedHarness.id,
                                       target: target.url, artifacts: result.artifacts)
        }

        if let postPush = delivery.postPush {
            log += await postPush(target, result)
        }
        pushLog = log
        pushing = false
    }

    private func probeHealth() async {
        guard let probe = delivery.healthProbe else { return }
        let result = await OpenClawService.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-m", "3", "-w", "%{http_code}", probe.url])
        probeOK = result.exitCode == 0 && result.stdout.trimmingCharacters(in: .whitespaces) != "000"
    }

    // MARK: Bits

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
