import XCTest
@testable import AdmiralCore

/// The line diff a tool card draws for an edit: trimmed to the change, with context, and
/// bounded work on a huge rewrite.
final class LineDiffTests: XCTestCase {
    private func numbered(_ count: Int, change: Int? = nil) -> String {
        (1...count).map { $0 == change ? "changed \($0)" : "line \($0)" }.joined(separator: "\n") + "\n"
    }

    func testIdenticalTextHasNoHunks() {
        XCTAssertEqual(LineDiff.hunks(old: numbered(20), new: numbered(20)), [])
    }

    func testOneChangedMiddleLineIsOneHunkWithContextEachSide() {
        let hunks = LineDiff.hunks(old: numbered(20), new: numbered(20, change: 10))
        XCTAssertEqual(hunks.count, 1)
        let hunk = hunks[0]
        XCTAssertEqual(hunk.oldStart, 7)
        XCTAssertEqual(hunk.newStart, 7)
        XCTAssertEqual(hunk.lines.map(\.kind), [.context, .context, .context, .removed, .added,
                                                 .context, .context, .context])
        XCTAssertEqual(hunk.lines[3].text, "line 10")
        XCTAssertEqual(hunk.lines[4].text, "changed 10")
        XCTAssertEqual(hunk.lines.first?.text, "line 7")
        XCTAssertEqual(hunk.lines.last?.text, "line 13")
    }

    func testANewFileIsAllAdded() {
        let hunks = LineDiff.hunks(old: "", new: "a\nb\nc\n")
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].lines, ["a", "b", "c"].map { LineDiff.Line(kind: .added, text: $0) })
        XCTAssertEqual(hunks[0].newStart, 1)
    }

    func testTwoDistantChangesAreTwoHunks() {
        let old = numbered(40)
        let new = old.replacingOccurrences(of: "line 5\n", with: "five\n")
            .replacingOccurrences(of: "line 35\n", with: "thirty-five\n")
        let hunks = LineDiff.hunks(old: old, new: new)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[1].oldStart, 32)
    }

    func testOverTheLimitIsOneHunkRemovedThenAdded() {
        let old = (1...30).map { "old \($0)" }.joined(separator: "\n")
        let new = (1...25).map { "new \($0)" }.joined(separator: "\n")
        let hunks = LineDiff.hunks(old: "keep\n" + old + "\nend\n", new: "keep\n" + new + "\nend\n", limit: 10)
        XCTAssertEqual(hunks.count, 1)
        let kinds = hunks[0].lines.map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .removed }.count, 30)
        XCTAssertEqual(kinds.filter { $0 == .added }.count, 25)
        let changes = kinds.filter { $0 != .context }
        XCTAssertEqual(changes, Array(repeating: .removed, count: 30) + Array(repeating: .added, count: 25))
        XCTAssertEqual(kinds.first, .context)
        XCTAssertEqual(kinds.last, .context)
    }

    /// The card's gutter: context lines carry both numbers, a removal only the old, an
    /// addition only the new, and each hunk restarts from its own starts.
    func testNumberedRowsCarryEachSidesLineNumbers() {
        let hunks = [
            LineDiff.Hunk(oldStart: 7, newStart: 7, lines: [
                .init(kind: .context, text: "a"), .init(kind: .removed, text: "b"),
                .init(kind: .added, text: "B"), .init(kind: .added, text: "B2"), .init(kind: .context, text: "c"),
            ]),
            LineDiff.Hunk(oldStart: 30, newStart: 31, lines: [.init(kind: .removed, text: "z")]),
        ]
        let rows = LineDiff.numbered(hunks)
        XCTAssertEqual(rows.map(\.old), [7, 8, nil, nil, 9, 30])
        XCTAssertEqual(rows.map(\.new), [7, nil, 8, 9, 10, nil])
        XCTAssertEqual(rows.map(\.hunk), [0, 0, 0, 0, 0, 1])
        XCTAssertEqual(rows.map(\.line.text), ["a", "b", "B", "B2", "c", "z"])
    }

    func testTailKeepsTheLastLines() {
        XCTAssertEqual(ChatTool.tail("1\n2\n3\n4\n", lines: 2), "3\n4")
        XCTAssertEqual(ChatTool.tail("1\n2\n3", lines: 2), "2\n3")
        XCTAssertEqual(ChatTool.tail("only", lines: 6), "only")
        XCTAssertEqual(ChatTool.tail("", lines: 6), "")
    }

    /// Long output is drawn from its end, within both a line and a byte cap; the note's count
    /// is the lines kept.
    func testShownCapsLinesAndBytes() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        XCTAssertEqual(ChatTool.shown(text, maxLines: 20), ChatTool.Shown(text: String(text.dropLast()), lines: 10, truncated: false))
        let byLines = ChatTool.shown(text, maxLines: 3)
        XCTAssertEqual(byLines, ChatTool.Shown(text: "line 8\nline 9\nline 10", lines: 3, truncated: true))
        // 20 bytes from the end lands mid "line 8"; the partial line goes.
        let byBytes = ChatTool.shown(text, maxLines: 100, maxBytes: 20)
        XCTAssertEqual(byBytes, ChatTool.Shown(text: "line 9\nline 10", lines: 2, truncated: true))
        // One endless line: the byte cap still holds, the partial line stays.
        let endless = String(repeating: "x", count: 10_000)
        let one = ChatTool.shown(endless, maxBytes: 100)
        XCTAssertEqual(one.text.count, 100)
        XCTAssertEqual(one.lines, 1)
        XCTAssertTrue(one.truncated)
        XCTAssertEqual(ChatTool.shown(""), ChatTool.Shown(text: "", lines: 0, truncated: false))
    }

    func testCappedRowsCountWhatIsLeftOut() {
        let rows = LineDiff.numbered([LineDiff.Hunk(oldStart: 1, newStart: 1,
                                                    lines: (1...7).map { .init(kind: .added, text: "\($0)") })])
        let capped = LineDiff.capped(rows, limit: 5)
        XCTAssertEqual(capped.rows.count, 5)
        XCTAssertEqual(capped.hidden, 2)
        XCTAssertEqual(LineDiff.capped(rows, limit: 50).hidden, 0)
    }
}
