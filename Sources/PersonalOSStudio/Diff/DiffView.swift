import SwiftUI

/// Unified line-diff rendering: insertions green, deletions red, unchanged context
/// collapsed to ±3 lines around changes. Monospaced, scrolls in its own container.
struct DiffView: View {
    let old: String
    let new: String

    var body: some View {
        let ops = LineDiff.diff(old: old, new: new)
        let rows = LineDiff.displayRows(ops)
        if rows.isEmpty {
            Label("No changes", systemImage: "equal.circle")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(12)
        } else {
            let stats = LineDiff.stats(ops)
            VStack(alignment: .leading, spacing: 4) {
                Text("+\(stats.added) −\(stats.removed)")
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            rowView(row)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: LineDiff.DisplayRow) -> some View {
        switch row {
        case .fold(let hidden):
            Text("··· \(hidden) unchanged line\(hidden == 1 ? "" : "s") ···")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.vertical, 2).padding(.horizontal, 6)
        case .line(let op):
            switch op {
            case .equal(let text):
                diffLine(" ", text, background: .clear, foreground: .secondary)
            case .insert(let text):
                diffLine("+", text, background: Color.green.opacity(0.14), foreground: .primary)
            case .delete(let text):
                diffLine("−", text, background: Color.red.opacity(0.14), foreground: .primary)
            }
        }
    }

    private func diffLine(_ marker: String, _ text: String, background: Color, foreground: Color) -> some View {
        HStack(spacing: 6) {
            Text(marker).font(.caption.monospaced()).foregroundStyle(.tertiary)
            Text(text.isEmpty ? " " : text)
                .font(.caption.monospaced())
                .foregroundStyle(foreground)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }
}
