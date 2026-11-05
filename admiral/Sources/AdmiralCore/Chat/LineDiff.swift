import Foundation

/// A line diff for a tool card's edit: what changed between two texts, as hunks with context.
///
/// The common prefix and suffix are trimmed first, so an edit to a big file costs only its
/// changed middle; that middle is diffed by LCS. A middle over `limit` lines on either side is
/// not diffed at all — it is one hunk of every removed line then every added line, so a
/// whole-file rewrite costs linear work, never `limit²`.
public enum LineDiff {
    public struct Line: Hashable, Sendable {
        public enum Kind: Sendable { case context, added, removed }
        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// `oldStart` / `newStart`: 1-based line numbers of the hunk's first line in each text
    /// (for a hunk with no lines on one side, where those lines would go).
    public struct Hunk: Hashable, Sendable {
        public var oldStart: Int
        public var newStart: Int
        public var lines: [Line]

        public init(oldStart: Int, newStart: Int, lines: [Line]) {
            self.oldStart = oldStart
            self.newStart = newStart
            self.lines = lines
        }
    }

    /// Trims the common prefix/suffix, LCS on the rest; if the middle exceeds `limit` lines on either side, one hunk
    /// of all removed then all added lines (bounded work). `context` lines around each change.
    public static func hunks(old: String, new: String, context: Int = 3, limit: Int = 1500) -> [Hunk] {
        let a = lines(old), b = lines(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)]), midB = Array(b[prefix..<(b.count - suffix)])
        guard !midA.isEmpty || !midB.isEmpty else { return [] }

        // The whole script: the prefix, the middle's edits, the suffix.
        var ops: [Line] = a[..<prefix].map { Line(kind: .context, text: $0) }
        if midA.count > limit || midB.count > limit {
            ops += midA.map { Line(kind: .removed, text: $0) } + midB.map { Line(kind: .added, text: $0) }
        } else {
            ops += script(midA, midB)
        }
        ops += a[(a.count - suffix)...].map { Line(kind: .context, text: $0) }
        return group(ops, context: context)
    }

    /// Lines of a text; a final newline ends the last line rather than starting an empty one.
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }

    /// The LCS edit script of two short line arrays; within a change, removals come before additions.
    private static func script(_ a: [String], _ b: [String]) -> [Line] {
        let n = a.count, m = b.count
        // lcs[i * (m + 1) + j] = the LCS length of a[i...] and b[j...].
        var lcs = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        let width = m + 1
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i * width + j] = a[i] == b[j]
                        ? lcs[(i + 1) * width + j + 1] + 1
                        : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
                }
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                out.append(Line(kind: .context, text: a[i]))
                i += 1
                j += 1
            } else if i < n, j == m || lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] {
                out.append(Line(kind: .removed, text: a[i]))
                i += 1
            } else {
                out.append(Line(kind: .added, text: b[j]))
                j += 1
            }
        }
        return out
    }

    /// Cuts the script into hunks: each change with `context` lines either side, merging changes
    /// whose context would touch.
    private static func group(_ ops: [Line], context: Int) -> [Hunk] {
        // Positions before each op, so a hunk knows where it starts in both texts.
        var oldAt: [Int] = [], newAt: [Int] = []
        var o = 0, n = 0
        for op in ops {
            oldAt.append(o)
            newAt.append(n)
            if op.kind != .added { o += 1 }
            if op.kind != .removed { n += 1 }
        }
        let changes = ops.indices.filter { ops[$0].kind != .context }
        guard let first = changes.first else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var start = first, end = first
        for index in changes.dropFirst() {
            if index - end > 2 * context + 1 {
                ranges.append(start...end)
                start = index
            }
            end = index
        }
        ranges.append(start...end)
        return ranges.map { range in
            let lo = max(0, range.lowerBound - context), hi = min(ops.count - 1, range.upperBound + context)
            return Hunk(oldStart: oldAt[lo] + 1, newStart: newAt[lo] + 1, lines: Array(ops[lo...hi]))
        }
    }
}
