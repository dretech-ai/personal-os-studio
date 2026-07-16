import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var showProvider = false
    @State private var showInterview = false
    @State private var showEnterprise = false

    var body: some View {
        VStack(spacing: 0) {
            if state.demoMode { demoBanner }
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            HarnessSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            // Active = a HarnessAdapter is registered for the harness.
            if state.isActive(state.selectedHarness) {
                OpenClawView()
            } else {
                ComingSoonView(harness: state.selectedHarness)
            }
        }
        .navigationTitle("Personal OS Studio")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if state.demoMode { state.exitDemoMode() } else { state.enterDemoMode() }
                } label: {
                    Label(state.demoMode ? "Exit demo" : "Demo",
                          systemImage: "theatermasks")
                }
                .help(state.demoMode
                      ? "Leave demo mode and return to your own personal OS"
                      : "Switch to the fictional demo OS (Nova Reyes, Orbit Labs) — harness delivery disabled")

                Button {
                    showInterview = true
                } label: {
                    Label("Interview", systemImage: "wand.and.stars")
                }
                .help("Build a canonical file by interview")
                .disabled(!state.store.isValidRoot)

                Button {
                    showEnterprise = true
                } label: {
                    Label("Enterprise", systemImage: "building.2")
                }
                .help(state.demoMode
                      ? "Unavailable in demo mode — fictional content never enters the enterprise repo"
                      : "Share, curate, and pull Enterprise content (AI-enabled)")
                .disabled(state.demoMode || !state.store.isValidRoot)

                Button {
                    showProvider = true
                } label: {
                    Label("Provider", systemImage: "gearshape.2")
                }
                .help("Choose the LLM provider (local or cloud)")
            }
        }
        .sheet(isPresented: $showProvider) {
            ProviderSettingsView(settings: state.settings)
        }
        .sheet(isPresented: $showInterview) {
            InterviewView(engine: state.interview, settings: state.settings)
                .environmentObject(state)
        }
        .sheet(isPresented: $showEnterprise) {
            EnterprisePanel().environmentObject(state)
        }
        // First-launch nudge (decided in AppState.init): configure OpenClaw explicitly.
        .sheet(isPresented: $state.showOpenClawNudge) {
            OpenClawSettingsView(settings: state.openclawSettings)
                .environmentObject(state)
        }
        // No valid canonical repo → onboarding (choose an existing repo or scaffold one).
        .sheet(isPresented: $state.showOnboarding) {
            OnboardingView()
                .environmentObject(state)
                .interactiveDismissDisabled(!state.store.isValidRoot)
        }
        // Availability dots read the live filesystem; re-evaluate them whenever the
        // app regains focus so a tool installed in a terminal shows up on switch-back.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshAvailability()
        }
    }

    /// Unmissable strip while the app is rooted on the fictional demo OS.
    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "theatermasks.fill")
            Text("**Demo mode** — Nova Reyes's personal OS (fictional). Orbit Labs, an invented studio. Harness delivery is disabled; edits are disposable and reset on re-entry.")
                .font(.caption)
            Spacer()
            Button("Exit demo") { state.exitDemoMode() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.22))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.orange.opacity(0.4)),
                 alignment: .bottom)
    }
}

struct HarnessSidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding(
            get: { state.selectedHarness.id },
            set: { id in
                if let h = Harness.all.first(where: { $0.id == id }) { state.selectedHarness = h }
            })) {

            Section("Personal OS") {
                Button {
                    state.showOnboarding = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("Source repo").font(.headline)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(state.store.isValidRoot ? state.store.rootURL.lastPathComponent : "not set — click to choose")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(state.store.contentCount) content file(s)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    } icon: {
                        Image(systemName: state.store.isValidRoot ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(state.store.isValidRoot ? .green : .orange)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose or create the canonical Agent OS repo")
                .padding(.vertical, 2)
            }

            Section("Train a harness") {
                ForEach(Harness.all) { harness in
                    HarnessRow(harness: harness,
                               isActive: state.isActive(harness),
                               availability: state.availability(harness))
                        .tag(harness.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                SnapshotBadge(git: state.git)
                VaultBadge(vault: state.vault)
                LLMProviderBadge(settings: state.settings)
                GatewayStatusBadge()
            }
            .padding(10)
        }
    }
}

/// Sidebar control for uncommitted canonical changes; click to snapshot (local commit).
struct SnapshotBadge: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var git: GitService
    @State private var showSnapshot = false

    var body: some View {
        if git.isRepo && !git.dirtyPaths.isEmpty {
            Button {
                showSnapshot = true
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(Color.orange).frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Canonical repo").font(.caption.weight(.medium))
                        Text("\(git.dirtyPaths.count) uncommitted change(s) · click to snapshot")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "camera.on.rectangle").foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Commit canonical changes locally (Studio never pushes)")
            .sheet(isPresented: $showSnapshot) {
                SnapshotSheet(git: git).environmentObject(state)
            }
        } else if git.isRepo && git.contentFilesIgnored {
            // Git-backed, but the PII posture gitignores every filled-in canonical file —
            // so there's nothing to snapshot. Say so instead of hiding all git UI.
            gitNote(icon: "lock.doc",
                    title: "Canonical files are gitignored",
                    detail: "Your filled-in files are PII and excluded from git — nothing to snapshot. History applies to tracked templates only.")
        } else if git.isRepo {
            gitNote(icon: "checkmark.seal",
                    title: "Canonical repo",
                    detail: "No uncommitted changes.")
        }
    }

    private func gitNote(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .help(detail)
    }
}

/// Sidebar control for the PII vault: status + last snapshot when enabled, an amber
/// nudge when the gitignored content has no backup. Click opens the vault sheet.
struct VaultBadge: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var vault: VaultService
    @State private var showVault = false

    var body: some View {
        Button {
            showVault = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: vault.enabled ? "lock.shield.fill" : "shield.slash")
                    .foregroundStyle(vault.enabled ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text("PII vault").font(.caption.weight(.medium))
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(vault.enabled ? "Encrypted snapshots of your content documents — click to manage"
                            : "Gitignored PII files currently have no backup — click to enable the vault")
        .sheet(isPresented: $showVault) {
            VaultSheet(vault: vault).environmentObject(state)
        }
    }

    private var detail: String {
        guard vault.enabled else { return "off — PII files have no backup" }
        if let last = vault.lastSnapshotDate {
            return "last snapshot \(last.formatted(.relative(presentation: .named)))"
        }
        return "enabled — no snapshots yet"
    }
}

/// Persistent sidebar control showing the current LLM provider + model, click to configure.
struct LLMProviderBadge: View {
    @ObservedObject var settings: LLMSettings
    @State private var showProvider = false

    var body: some View {
        Button {
            showProvider = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(settings.isReady ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 0) {
                    Text("LLM provider").font(.caption.weight(.medium))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose the LLM provider (local Ollama or a cloud API key)")
        .sheet(isPresented: $showProvider) {
            ProviderSettingsView(settings: settings)
        }
    }

    private var subtitle: String {
        guard settings.isReady else { return "Not set up · click to configure" }
        let model = settings.currentModel
        return model.isEmpty ? settings.kind.displayName : "\(settings.kind.displayName) · \(model)"
    }
}

struct HarnessRow: View {
    let harness: Harness
    /// Derived from adapter registration (AppState.isActive), not static data.
    let isActive: Bool
    /// Real tool presence on this machine (AppState.availability). The dot must tell
    /// the truth: green = detected/configured, hollow = supported but not installed.
    let availability: (available: Bool, note: String)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: harness.symbol)
                .frame(width: 22)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(harness.name).fontWeight(.medium)
                Text(harness.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !isActive {
                Text("Soon")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .foregroundStyle(.secondary)
            } else if let availability {
                if availability.available {
                    Circle().fill(.green).frame(width: 8, height: 8)
                        .help(availability.note)
                } else {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                        .help("Supported, but \(availability.note.prefix(1).lowercased() + availability.note.dropFirst())")
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(isActive ? 1 : 0.75)
    }
}

struct GatewayStatusBadge: View {
    @EnvironmentObject var state: AppState
    @State private var showConfig = false

    var body: some View {
        Button {
            showConfig = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 0) {
                    Text("OpenClaw").font(.caption.weight(.medium))
                    Text(statusText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if state.openclawSettings.isConfigured {
                    Button {
                        Task { await state.openclaw.checkHealth() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Re-check gateway health")
                } else {
                    Image(systemName: "gearshape").foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Configure the OpenClaw install (location, gateway, container)")
        .sheet(isPresented: $showConfig) {
            OpenClawSettingsView(settings: state.openclawSettings)
                .environmentObject(state)
        }
    }

    var color: Color {
        switch state.openclaw.health {
        case .unconfigured: return .gray
        case .healthy: return .green
        case .checking, .unknown: return .yellow
        case .down: return .red
        }
    }
    var statusText: String {
        switch state.openclaw.health {
        case .unconfigured: return "not configured · click to set up"
        case .unknown: return "not checked"
        case .checking: return "checking…"
        case .healthy: return "gateway healthy"
        case .down(let m): return m
        }
    }
}
