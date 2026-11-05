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
}
