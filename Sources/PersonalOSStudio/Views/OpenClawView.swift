import SwiftUI

struct OpenClawView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HSplitView {
            CanonicalBrowser()
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 400)
            EditorPane()
                .frame(minWidth: 300)
            BuildPushPanel()
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 440)
        }
    }
}

// MARK: - Canonical browser (left)

struct CanonicalBrowser: View {
    @EnvironmentObject var state: AppState
    @State private var expanded: Set<Layer> = Set(Layer.allCases)
    @State private var showNewDoc = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Personal OS layers").font(.headline)
                Spacer()
                Button { state.store.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Reload canonical files from disk")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Text("Check files to include when training. Load order: identity → context → skills → memory → connections.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()

            List {
                ForEach(Layer.allCases) { layer in
                    layerSection(layer)
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(isPresented: $showNewDoc) {
            InterviewView(engine: state.interview, settings: state.settings)
                .environmentObject(state)
        }
    }

    /// The instance template behind a multi layer's "+ New …" button (skills →
    /// skill.template.md, memory → persistent.entry.template.md, …). nil hides the +.
    private func instanceTemplate(for layer: Layer) -> CanonicalFile? {
        guard layer.cardinality == .multi else { return nil }
        let base: String
        switch layer {
        case .skills: base = "skill.template.md"
        case .memory: base = "persistent.entry.template.md"
        case .connections: base = "connection.template.md"
        case .agents: base = "agent.template.md"
        default: return nil
        }
        return state.store.files(layer).first { $0.isTemplate && $0.filename == base }
    }

    @ViewBuilder
    func layerSection(_ layer: Layer) -> some View {
        // Templates are authoring scaffolds the Interview reads from disk — they are
        // not browsable documents. Hiding them prevents a template + its generated file
        // (e.g. identity.template.md + identity.md) from showing as duplicates.
        let files = state.store.files(layer).filter { !$0.isTemplate }
        let includedCount = files.filter { $0.include }.count
        Section {
            if expanded.contains(layer) {
                if files.isEmpty {
                    Text("No files yet — use Interview to create one.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(files) { file in
                    FileRow(file: file)
                }
            }
        } header: {
            Button {
                if expanded.contains(layer) { expanded.remove(layer) } else { expanded.insert(layer) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded.contains(layer) ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: layer.symbol).foregroundStyle(Color.accentColor)
                    Text(layer.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    if includedCount > 0 {
                        Text("\(includedCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                // Multi layers hold many documents — offer "add another" right here.
                if let template = instanceTemplate(for: layer) {
                    Button {
                        state.pendingCreateTemplate = template
                        showNewDoc = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("New \(layer.instanceNoun) (interview)")
                    .padding(.trailing, includedCount > 0 ? 28 : 0)
                }
            }
        }
    }
}

struct FileRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var file: CanonicalFile

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { file.include },
                set: { file.include = $0; state.buildResult = nil }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(file.isTemplate)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(file.isTemplate ? .secondary : .primary)
                HStack(spacing: 5) {
                    validationDot
                    if state.git.isDirty(file) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .help("Uncommitted changes — snapshot from the sidebar")
                    }
                    DesignationTag(designation: file.designation)
                    Text(file.kindBadge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let ct = file.contextType { Text(ct).font(.caption2).foregroundStyle(.tertiary) }
                    if let sc = file.scope { Text(sc).font(.caption2).foregroundStyle(.tertiary) }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { state.selectedFile = file }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(state.selectedFile?.id == file.id ? Color.accentColor.opacity(0.15) : .clear)
        )
    }

    var displayTitle: String {
        // Prefer the frontmatter title, trimmed of the "(FICTIONAL SAMPLE)" noise.
        let t = file.title.replacingOccurrences(of: " (FICTIONAL SAMPLE)", with: "")
        return t.count > 46 ? file.filename : t
    }

    /// Validation status: red = errors, amber = warnings only, green = clean.
    @ViewBuilder
    var validationDot: some View {
        let findings = state.findings(for: file)
        let hasError = findings.contains { $0.severity == .error }
        Circle()
            .fill(hasError ? Color.red : (findings.isEmpty ? Color.green : Color.orange))
            .frame(width: 6, height: 6)
            .help(findings.isEmpty
                  ? "Passes validation"
                  : findings.map { "\($0.rule): \($0.message)" }.joined(separator: "\n"))
    }
}

struct DesignationTag: View {
    let designation: Designation
    var body: some View {
        Text(designation.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
    var color: Color {
        switch designation {
        case .pii: return .red
        case .enterprise: return .orange
        case .pub: return .green
        case .unknown: return .gray
        }
    }
}
