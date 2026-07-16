import Foundation

/// A minimal LCS-based line differ. O(n·m) — canonical docs and workspace files are
/// small (well under a few thousand lines), so simplicity wins over Myers.
enum LineDiff {

    enum Op: Equatable {
        case equal(String)
        case insert(String)
        case delete(String)
    }

    /// Line-level edit script turning `old` into `new`.
    static func diff(old: String, new: String) -> [Op] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count

        // LCS table.
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        // Walk the table.
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.equal(a[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.delete(a[i])); i += 1
            } else {
                ops.append(.insert(b[j])); j += 1
            }
        }
        while i < n { ops.append(.delete(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }

    /// (+insertions, −deletions) counts for a summary line.
    static func stats(_ ops: [Op]) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for op in ops {
            if case .insert = op { added += 1 }
            if case .delete = op { removed += 1 }
        }
        return (added, removed)
    }

    /// Whether two texts differ at all (fast path for push planning).
    static func changed(old: String, new: String) -> Bool { old != new }

    /// Property check used by tests: replaying the ops reproduces `new`.
    static func apply(_ ops: [Op]) -> String {
        var out: [String] = []
        for op in ops {
            switch op {
            case .equal(let l), .insert(let l): out.append(l)
            case .delete: break
            }
        }
        return out.joined(separator: "\n")
    }

    /// Collapse an op list into display rows with ±`context` lines around changes;
    /// unchanged runs beyond that render as a fold marker.
    enum DisplayRow: Equatable {
        case line(Op)
        case fold(hidden: Int)
    }

    static func displayRows(_ ops: [Op], context: Int = 3) -> [DisplayRow] {
        // Indices of non-equal ops.
        let changeIdx = ops.enumerated().compactMap { i, op -> Int? in
            if case .equal = op { return nil } else { return i }
        }
        guard !changeIdx.isEmpty else { return [] }

        var visible = Set<Int>()
        for idx in changeIdx {
            for k in max(0, idx - context)...min(ops.count - 1, idx + context) {
                visible.insert(k)
            }
        }

        var rows: [DisplayRow] = []
        var i = 0
        while i < ops.count {
            if visible.contains(i) {
                rows.append(.line(ops[i]))
                i += 1
            } else {
                var hidden = 0
                while i < ops.count && !visible.contains(i) { hidden += 1; i += 1 }
                rows.append(.fold(hidden: hidden))
            }
        }
        return rows
    }
}
