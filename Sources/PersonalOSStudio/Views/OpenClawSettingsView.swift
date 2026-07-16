import SwiftUI
import AppKit

/// Sheet for configuring the OpenClaw harness: state dir, gateway URL, container name.
/// Studio detects and *suggests* known locations but wires nothing until the user
/// confirms here. Mirrors the ProviderSettingsView pattern.
struct OpenClawSettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var settings: OpenClawSettings
    @Environment(\.dismiss) var dismiss

    @State private var pathField: String = ""
    @State private var gatewayField: String = ""
    @State private var containerField: String = ""
    @State private var detectedDirs: [String] = []
    @State private var detectedContainers: [String] = []
    @State private var detectingContainers = false
    @State private var testResult: String?
    @State private var testOK = false
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "pawprint.fill").foregroundStyle(Color.accentColor)
                Text("OpenClaw Configuration").font(.headline)
                Spacer()
                Button("Done") { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Studio doesn't assume OpenClaw is installed. Point it at your install — detected locations are suggestions until you confirm.")
                        .font(.caption).foregroundStyle(.secondary)
                    stateDirSection
                    gatewaySection
                    containerSection
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 520)
        .onAppear(perform: load)
    }

    // MARK: State dir

    private var stateDirSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("State directory")
            Text("The host folder OpenClaw runs from — contains openclaw.json and workspace folders.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                TextField("~/.openclaw or /Volumes/…/openclaw", text: $pathField)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button("Browse…") { browse() }
            }
            if !detectedDirs.isEmpty {
                HStack(spacing: 6) {
                    Text("Detected:").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(detectedDirs, id: \.self) { dir in
                        Button(dir) { pathField = dir }
                            .buttonStyle(.bordered).controlSize(.small)
                            .font(.caption2.monospaced())
                    }
                }
            }
            dirFeedback
        }
    }

    @ViewBuilder
    private var dirFeedback: some View {
        let trimmed = pathField.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Label("Not configured — pushing to OpenClaw is disabled until set.", systemImage: "circle.dashed")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            let expanded = (trimmed as NSString).expandingTildeInPath
            switch probeDirectory(at: expanded) {
            case .missing:
                Label("Directory not found.", systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            case .accessDenied:
                VStack(alignment: .leading, spacing: 6) {
                    Label("macOS is blocking access to this location (removable-volume permission denied).", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.red)
                    Button("Open Privacy Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                    Text("Enable Removable Volumes for Personal OS Studio under Files & Folders, then re-open this sheet.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            case .workspaces(0):
                Label("Directory exists but contains no workspace folders.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            case .workspaces(let count):
                Label("\(count) workspace(s) found.", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }

    // MARK: Gateway

    private var gatewaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Gateway URL")
            Text("Base URL of the OpenClaw gateway; health checks hit /healthz and the Control UI link derives from it.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                TextField(OpenClawSettings.defaultGatewayBaseURL, text: $gatewayField)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                Button {
                    Task { await testGateway() }
                } label: {
                    HStack(spacing: 4) {
                        if testing { ProgressView().controlSize(.small) }
                        Text("Test gateway")
                    }
                }
                .disabled(testing || gatewayField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let msg = testResult {
                Label(msg, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(testOK ? .green : .red)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Container

    private var containerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label("Docker container (optional)")
                Spacer()
                Button {
                    Task {
                        detectingContainers = true
                        detectedContainers = await OpenClawSettings.detectContainers()
                        detectingContainers = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if detectingContainers { ProgressView().controlSize(.small) }
                        Text("Detect")
                    }
                }
                .controlSize(.small)
            }
            Text("Used by the “Restart gateway container” action. Leave empty if OpenClaw doesn't run in Docker — restart will be disabled.")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("container name", text: $containerField)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            if !detectedContainers.isEmpty {
                HStack(spacing: 6) {
                    Text("Detected:").font(.caption2).foregroundStyle(.tertiary)
                    ForEach(detectedContainers, id: \.self) { name in
                        Button(name) { containerField = name }
                            .buttonStyle(.bordered).controlSize(.small)
                            .font(.caption2.monospaced())
                    }
                }
            } else if detectingContainers == false && detectedContainers.isEmpty {
                EmptyView()
            }
        }
    }

    // MARK: Actions

    private func load() {
        pathField = settings.stateDirPath ?? ""
        gatewayField = settings.gatewayBaseURL
        containerField = settings.containerName
        testResult = nil
        // Detection probes external volumes — keep it off the main thread.
        Task {
            let dirs = await Task.detached { OpenClawSettings.detectStateDirs() }.value
            detectedDirs = dirs
        }
    }

    private func save() {
        let trimmed = pathField.trimmingCharacters(in: .whitespaces)
        settings.stateDirPath = trimmed.isEmpty ? nil : trimmed
        let gw = gatewayField.trimmingCharacters(in: .whitespaces)
        settings.gatewayBaseURL = gw.isEmpty ? OpenClawSettings.defaultGatewayBaseURL : gw
        settings.containerName = containerField.trimmingCharacters(in: .whitespaces)
        state.reconfigureOpenClaw()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose your OpenClaw state directory"
        if panel.runModal() == .OK, let url = panel.url {
            pathField = url.path
        }
    }

    enum DirProbe: Equatable {
        case missing
        case accessDenied
        case workspaces(Int)
    }

    /// Probe a candidate state dir, distinguishing "empty" from "macOS blocked the read"
    /// (TCC removable-volume denial surfaces as NSFileReadNoPermissionError / EPERM).
    private func probeDirectory(at path: String) -> DirProbe {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return .missing }
        do {
            let entries = try fm.contentsOfDirectory(atPath: path)
            return .workspaces(entries.filter { $0 == "workspace" || $0.hasPrefix("workspace-") }.count)
        } catch {
            let ns = error as NSError
            let denied = ns.code == NSFileReadNoPermissionError
                || (ns.underlyingPosixCode == EPERM || ns.underlyingPosixCode == EACCES)
            return denied ? .accessDenied : .missing
        }
    }

    private func testGateway() async {
        testing = true
        testResult = nil
        // Test the URL as typed in the sheet, without persisting yet.
        let base = gatewayField.trimmingCharacters(in: .whitespaces)
        let url = (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/healthz"
        let result = await OpenClawService.run("/usr/bin/curl", ["-s", "-m", "4", url])
        if result.exitCode == 0, !result.stdout.isEmpty {
            testOK = true
            testResult = "Gateway responded: \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))"
        } else {
            testOK = false
            testResult = "No response from \(url)"
        }
        testing = false
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}
