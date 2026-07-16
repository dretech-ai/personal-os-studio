import SwiftUI

/// Right pane: train (run the OpenClaw adapter), preview artifacts, push to a
/// workspace, then restart the gateway.
struct BuildPushPanel: View {
    @EnvironmentObject var state: AppState
    @State private var selectedArtifact: BuildArtifact?
    @State private var backup = true
    @State private var confirmPush = false
    @State private var restarting = false
    @State private var restartMessage: String?
    @State private var showConfig = false
    @State private var showConnections = false
    @State private var showBackfeed = false
    @State private var showEvals = false
    @State private var diffArtifact: BuildArtifact?

    var body: some View {
        // Dispatch on the selected harness's delivery kind: clipboard-delivered
        // harnesses get the copy-block panel; OpenClaw keeps its bespoke rich panel
        // (settings/TCC/restart); other directory harnesses use the generic panel.
        switch state.adapter(for: state.selectedHarness)?.delivery {
        case .clipboard(let cd):
            ClipboardDeliveryPanel(delivery: cd)
        case .directory(let dd) where state.selectedHarness.id != "openclaw":
            GenericDirectoryPanel(delivery: dd)
        default:
            directoryBody
        }
    }

    private var directoryBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    targetSection
                    trainSection
                    connectionsSection
                    backfeedSection
                    if let result = state.buildResult {
                        artifactsSection(result)
                        warningsSection(result)
                        pushSection(result)
                    }
                    if !state.openclaw.lastPushLog.isEmpty { pushLogSection }
                }
                .padding(12)
            }
        }
        .sheet(item: $selectedArtifact) { art in
            ArtifactPreviewSheet(artifact: art)
        }
        .confirmationDialog("Push to OpenClaw?", isPresented: $confirmPush, titleVisibility: .visible) {
            Button("Write to \(state.selectedWorkspace?.displayName ?? "?") — \(pushPlan?.summary ?? "")", role: .destructive) {
                doPush()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This overwrites workspace files in \(state.selectedWorkspace?.url.path ?? ""). Unchanged files are skipped. \(backup ? "Existing files are backed up (.bak-studio)." : "No backups will be made.")")
        }
        .sheet(item: $diffArtifact) { art in
            artifactDiffSheet(art)
        }
        .sheet(isPresented: $showConnections) {
            ConnectionsPanel().environmentObject(state)
        }
        .sheet(isPresented: $showBackfeed) {
            if let ws = state.selectedWorkspace {
                BackfeedPanel(harnessID: "openclaw", harnessName: "OpenClaw", target: ws.url)
                    .environmentObject(state)
            }
        }
        .sheet(isPresented: $showEvals) {
            EvalsPanel(harnessID: "openclaw", harnessName: "OpenClaw")
                .environmentObject(state)
        }
        // Self-heal: re-probe on appear unless already healthy, so returning to the
        // panel after starting the gateway picks it up without a manual re-check.
        .task {
            if state.openclawSettings.isConfigured && !state.openclaw.health.isHealthy {
                await state.openclaw.checkHealth()
            }
        }
    }

    // MARK: Header

    var header: some View {
        HStack {
            Image(systemName: "pawprint.fill").foregroundStyle(Color.accentColor)
            Text("Train → OpenClaw").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Target workspace

    var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("1 · Target workspace")
            if !state.openclawSettings.isConfigured {
                warnBox("OpenClaw isn't configured. Studio doesn't assume it's installed — point it at your install to enable pushing.")
                Button {
                    showConfig = true
                } label: {
                    Label("Configure OpenClaw…", systemImage: "gearshape.2")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            } else if state.openclaw.workspaces.isEmpty {
                if state.openclaw.discoveryBlocked {
                    warnBox("macOS is blocking access to \(state.openclaw.stateDir?.path ?? "the configured directory") (removable-volume permission). Allow it under Privacy & Security → Files & Folders, then retry.")
                    HStack {
                        Button("Open Privacy Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Retry") { state.reconfigureOpenClaw() }
                    }
                    .controlSize(.small)
                } else {
                    warnBox("No workspace folders found in \(state.openclaw.stateDir?.path ?? "the configured directory"). Check the location in OpenClaw settings.")
                    Button("Change location…") { showConfig = true }
                        .controlSize(.small)
                }
            } else {
                Picker("", selection: Binding(
                    get: { state.selectedWorkspace ?? state.openclaw.workspaces.first! },
                    set: { state.selectedWorkspace = $0 })) {
                    ForEach(state.openclaw.workspaces) { ws in
                        Text(ws.displayName).tag(ws)
                    }
                }
                .labelsHidden()
                Text(state.selectedWorkspace?.url.path ?? "")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            if state.openclawSettings.isConfigured {
                HStack(spacing: 6) {
                    gatewayDot
                    Text(gatewayText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let controlURL = URL(string: state.openclaw.controlUI),
                       !state.openclaw.controlUI.isEmpty {
                        Link("Control UI", destination: controlURL)
                            .font(.caption)
                    }
                }
            }
        }
        .sheet(isPresented: $showConfig) {
            OpenClawSettingsView(settings: state.openclawSettings)
                .environmentObject(state)
        }
    }

    // MARK: Connections

    @ViewBuilder
    var connectionsSection: some View {
        if !state.store.files(.connections).filter({ !$0.isTemplate }).isEmpty && !state.demoMode {
            Button {
                showConnections = true
            } label: {
                Label("Manage connections (openclaw.json)…", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity)
            }
            .help("Guided registration of canonical connection docs into the gateway config")
        }
    }

    // MARK: Backfeed (F15) + Evals (F16)

    @ViewBuilder
    var backfeedSection: some View {
        if state.selectedWorkspace != nil && !state.demoMode {
            Button {
                showBackfeed = true
            } label: {
                Label("Check for harness updates…", systemImage: "arrow.uturn.backward.circle")
                    .frame(maxWidth: .infinity)
            }
            .help("Detect what changed in the workspace since the last push and fold it back into canonical as reviewed proposals")
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

    // MARK: Train

    var trainSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("2 · Train (apply adapter)")
            Text("Transforms the checked canonical files into SOUL.md, AGENTS.md, skills/, MEMORY.md per the OpenClaw adapter.")
                .font(.caption2).foregroundStyle(.secondary)
            Button {
                state.rebuild()
                selectedArtifact = nil
            } label: {
                Label("Train from canonical", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Artifacts

    func artifactsSection(_ result: BuildResult) -> some View {
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
                        if deployedText(for: art) != nil {
                            Button {
                                diffArtifact = art
                            } label: {
                                Image(systemName: "plus.forwardslash.minus").font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Diff against the deployed copy")
                        }
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

    /// Contents of the currently deployed copy of an artifact, if the workspace has one.
    private func deployedText(for artifact: BuildArtifact) -> String? {
        guard let ws = state.selectedWorkspace else { return nil }
        return try? String(contentsOf: ws.url.appendingPathComponent(artifact.relativePath), encoding: .utf8)
    }

    private var pushPlan: PushPlan? {
        guard let result = state.buildResult, let ws = state.selectedWorkspace else { return nil }
        return PushPlan.plan(result, into: ws.url)
    }

    private func artifactDiffSheet(_ artifact: BuildArtifact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "plus.forwardslash.minus")
                Text("\(artifact.relativePath) — deployed → new").font(.headline.monospaced())
                Spacer()
                Button("Done") { diffArtifact = nil }.keyboardShortcut(.defaultAction)
            }
            DiffView(old: deployedText(for: artifact) ?? "", new: artifact.contents)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 700, height: 480)
    }

    func warningsSection(_ result: BuildResult) -> some View {
        Group {
            if !result.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(result.warnings, id: \.self) { w in
                        warnBox(w)
                    }
                }
            }
        }
    }

    // MARK: Push

    func pushSection(_ result: BuildResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("4 · Push & restart")
            if state.demoMode {
                warnBox("Demo mode — harness delivery is disabled. Training and previews above show exactly what WOULD be written.")
            }
            Toggle("Back up existing files (.bak-studio)", isOn: $backup)
                .font(.caption)
            if result.effectiveDesignation == .pii {
                warnBox("Output is PII. It will be written only into the local workspace on the external drive. Never commit that tree.")
            }
            Button {
                confirmPush = true
            } label: {
                Label("Push to \(state.selectedWorkspace?.displayName ?? "workspace")", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(result.artifacts.isEmpty || state.selectedWorkspace == nil || state.demoMode)

            Button {
                Task {
                    restarting = true
                    restartMessage = await state.openclaw.restartContainer()
                    await state.openclaw.checkHealth()
                    restarting = false
                }
            } label: {
                Label(restarting ? "Restarting…" : "Restart gateway container", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .disabled(restarting || state.openclaw.containerName.isEmpty || state.demoMode)
            .help(state.openclaw.containerName.isEmpty
                  ? "Set the container name in OpenClaw settings to enable restarts"
                  : "docker restart \(state.openclaw.containerName)")
            if let m = restartMessage {
                Text(m).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    var pushLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Push log")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.openclaw.lastPushLog, id: \.self) { line in
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

    func doPush() {
        guard let result = state.buildResult, let ws = state.selectedWorkspace else { return }
        // Skip unchanged artifacts; log what was skipped so the omission is visible.
        let plan = PushPlan.plan(result, into: ws.url)
        var filtered = BuildResult()
        filtered.artifacts = plan.toWrite
        filtered.warnings = result.warnings
        state.openclaw.push(filtered, to: ws, backup: backup)
        if !plan.unchanged.isEmpty {
            state.openclaw.lastPushLog += plan.unchanged.map { "· \($0.relativePath) unchanged, skipped" }
        }
        // Baseline for drift detection (F15): record the FULL artifact set — skipped
        // unchanged files are on disk and part of what was pushed.
        PushLedger.standard.record(harness: "openclaw", target: ws.url, artifacts: result.artifacts)
    }

    // MARK: Bits

    func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    func warnBox(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            Text(s).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    // Tri-state like the sidebar badge: the launch health check is async, so
    // "not checked yet" must read as pending (yellow), never as unreachable (red).
    var gatewayDot: some View {
        let color: Color
        switch state.openclaw.health {
        case .healthy: color = .green
        case .checking, .unknown: color = .yellow
        case .down: color = .red
        case .unconfigured: color = .gray
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }
    var gatewayText: String {
        switch state.openclaw.health {
        case .healthy: return "gateway healthy"
        case .checking: return "checking gateway…"
        case .unknown: return "gateway not checked yet"
        case .down: return "gateway unreachable"
        case .unconfigured: return "gateway not configured"
        }
    }
}

// MARK: - Artifact preview

struct ArtifactPreviewSheet: View {
    let artifact: BuildArtifact
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "doc.text.fill")
                Text(artifact.relativePath).font(.headline.monospaced())
                DesignationTag(designation: artifact.designation)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(artifact.contents, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(artifact.contents)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
        .frame(width: 700, height: 560)
    }
}
