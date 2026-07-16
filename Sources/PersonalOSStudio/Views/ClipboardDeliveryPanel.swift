import SwiftUI
import AppKit

/// Right pane for clipboard-delivered harnesses (no file surface — e.g. Claude Cowork):
/// train, then copy each named block into the tool's UI following its paste steps.
struct ClipboardDeliveryPanel: View {
    @EnvironmentObject var state: AppState
    let delivery: ClipboardDelivery

    @State private var copiedBlock: String?
    @State private var showEvals = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "doc.on.clipboard").foregroundStyle(Color.accentColor)
                Text("Train → \(state.selectedHarness.name)").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                    Text(delivery.note)
                        .font(.caption).foregroundStyle(.secondary)
                    if state.demoMode {
                        Label("Demo mode — copying is disabled; the blocks below show exactly what WOULD be pasted.",
                              systemImage: "theatermasks")
                            .font(.caption2).foregroundStyle(.orange)
                    }

                    Button {
                        state.rebuild()
                        copiedBlock = nil
                    } label: {
                        Label("Train from canonical", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    if let result = state.buildResult {
                        if !result.warnings.isEmpty {
                            ForEach(result.warnings, id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Button {
                            showEvals = true
                        } label: {
                            Label("Evaluate against spec…", systemImage: "gauge.with.needle")
                                .frame(maxWidth: .infinity)
                        }
                        .help("Run the eval suite against these paste blocks and score behavior against the spec")
                        ForEach(result.artifacts) { block in
                            blockCard(block)
                        }
                    }
                }
                .padding(12)
            }
        }
        .sheet(isPresented: $showEvals) {
            EvalsPanel(harnessID: state.selectedHarness.id,
                       harnessName: state.selectedHarness.name)
                .environmentObject(state)
        }
    }

    private func blockCard(_ block: BuildArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(block.relativePath).font(.subheadline.weight(.semibold))
                DesignationTag(designation: block.designation)
                Spacer()
                Text("\(block.byteCount)B").font(.caption2).foregroundStyle(.tertiary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(block.contents, forType: .string)
                    copiedBlock = block.relativePath
                } label: {
                    Label(copiedBlock == block.relativePath ? "Copied" : "Copy",
                          systemImage: copiedBlock == block.relativePath ? "checkmark" : "doc.on.doc")
                }
                .disabled(state.demoMode)
                .help(state.demoMode ? "Demo mode — harness delivery is disabled" : "Copy this block to the clipboard")
            }
            if let steps = delivery.instructions[block.relativePath], !steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). \(step)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ScrollView {
                Text(block.contents)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}
