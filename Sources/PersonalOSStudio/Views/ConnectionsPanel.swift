import SwiftUI

/// Guided connections registration for OpenClaw: parses canonical connection docs,
/// shows registered-vs-unregistered against the live openclaw.json, and — when the
/// gateway exposes a recognized MCP section — performs previewed, backed-up
/// registration. Never writes without explicit confirmation; never writes secrets.
struct ConnectionsPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss

    @State private var docs: [ConnectionDoc] = []
    @State private var config: OpenClawConfig?
    @State private var previewDoc: ConnectionDoc?
    @State private var previewProposal: OpenClawConfig.Proposal?
    @State private var log: [String] = []
    @State private var restarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(Color.accentColor)
                Text("Connections → openclaw.json").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    configStatus
                    if docs.isEmpty {
                        Text("No connection docs in the canonical repo.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(docs) { doc in
                        docRow(doc)
                    }
                    if !log.isEmpty { logSection }
                }
                .padding(12)
            }
        }
        .frame(width: 640, height: 520)
        .onAppear(perform: reload)
        .sheet(item: $previewDoc) { doc in
            previewSheet(doc)
        }
    }

    // MARK: Config status

    @ViewBuilder
    private var configStatus: some View {
        if let config {
            switch config.state {
            case .missing(let msg), .unparseable(let msg):
                warnBox("\(msg) — registration unavailable; diagnosis only.")
            case .loaded:
                if config.surface == .none {
                    warnBox("This gateway's openclaw.json has no recognized MCP section — Studio offers copy-ready entries and guidance instead of writing (confirm the path with `openclaw config get`).")
                } else {
                    Label("Config loaded · \(config.registeredNames.count) MCP server(s) registered", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
        } else {
            warnBox("OpenClaw isn't configured — set the state directory first.")
        }
    }

    // MARK: Rows

    private func docRow(_ doc: ConnectionDoc) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(doc.name).font(.subheadline.weight(.semibold).monospaced())
                Text(doc.mechanism).font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.blue.opacity(0.15)))
                if doc.isReadOnly {
                    Text("read-only").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                DesignationTag(designation: doc.file.designation)
                Spacer()
                statusBadge(doc)
            }
            Text("\(doc.capabilities.count) capabilit\(doc.capabilities.count == 1 ? "y" : "ies") · \(doc.file.filename)")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(doc.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            actionRow(doc)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    @ViewBuilder
    private func statusBadge(_ doc: ConnectionDoc) -> some View {
        if doc.isMCP {
            if config?.registeredNames.contains(doc.name) == true {
                Label("registered", systemImage: "checkmark.seal.fill")
                    .font(.caption2).foregroundStyle(.green)
            } else {
                Label("unregistered", systemImage: "circle.dashed")
                    .font(.caption2).foregroundStyle(.orange)
            }
        } else {
            Label("no registration needed", systemImage: "info.circle")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func actionRow(_ doc: ConnectionDoc) -> some View {
        if doc.isMCP {
            if config?.registeredNames.contains(doc.name) != true {
                Button {
                    previewProposal = config?.propose(doc)
                    previewDoc = doc
                } label: {
                    Label("Register…", systemImage: "plus.circle")
                }
                .controlSize(.small)
            }
        } else {
            Text(mechanismGuidance(doc.mechanism))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Non-mcp guidance from the OpenClaw adapter spec's mechanism table.
    private func mechanismGuidance(_ mechanism: String) -> String {
        switch mechanism.lowercased() {
        case "cli":
            return "Invoked through the gateway's sandboxed shell tool — the Configuration block is the invocation pattern; no config registration."
        case "api":
            return "curl/SDK via the sandboxed shell — keys stay in the environment; no config registration."
        case "builtin":
            return "OpenClaw native capability (TOOLS.md catalog) — nothing to register."
        default:
            return "Unknown mechanism — follow the doc's Configuration section manually."
        }
    }

    // MARK: Preview / confirm

    @ViewBuilder
    private func previewSheet(_ doc: ConnectionDoc) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Register \(doc.name)").font(.headline)
                Spacer()
                // Every proposal outcome needs an exit — only .writable has its own
                // Cancel, so anchor a Close (and Esc) here for all cases.
                Button("Close") { previewDoc = nil }
                    .keyboardShortcut(.cancelAction)
            }
            switch previewProposal {
            case .alreadyRegistered:
                Label("Already registered.", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            case .refusedSecret(let reason):
                Label(reason, systemImage: "xmark.shield.fill")
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            case .manualOnly(let snippet, let guidance):
                Label(guidance, systemImage: "hand.point.right")
                    .font(.caption).foregroundStyle(.secondary)
                snippetView(snippet)
                Button("Copy proposed entry") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }
            case .writable(let newConfigText, let snippet):
                Text("Entry to add:").font(.caption.weight(.semibold))
                snippetView(snippet)
                if !doc.securityNotes.isEmpty {
                    Label(doc.securityNotes.components(separatedBy: "\n").first ?? "",
                          systemImage: "shield.lefthalf.filled")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { previewDoc = nil }
                    Button("Back up & write", role: .destructive) {
                        if let config {
                            log = config.write(newConfigText: newConfigText)
                            reload()
                            log.append("→ Restart the gateway container for changes to take effect.")
                        }
                        previewDoc = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            case nil:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 560, height: 380)
    }

    private func snippetView(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(maxHeight: 180)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(log, id: \.self) { line in
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(line.hasPrefix("✗") ? .red : .secondary)
            }
            if log.contains(where: { $0.hasPrefix("✓ wrote") }) {
                Button {
                    Task {
                        restarting = true
                        let msg = await state.openclaw.restartContainer()
                        log.append(msg)
                        restarting = false
                    }
                } label: {
                    Label(restarting ? "Restarting…" : "Restart gateway container", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(restarting || state.openclaw.containerName.isEmpty)
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

    // MARK: Data

    private func reload() {
        docs = state.store.files(.connections)
            .filter { !$0.isTemplate }
            .map { ConnectionDoc.parse($0, store: state.store) }
        if let stateDir = state.openclaw.stateDir {
            config = OpenClawConfig.load(stateDir: stateDir)
        } else {
            config = nil
        }
    }
}
