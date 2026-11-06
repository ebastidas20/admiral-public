import XCTest
@testable import AdmiralCore

/// File paths in a chat message become links — but only ones that are really there.
final class ChatLinksTests: XCTestCase {
    private let cwd = "/work"
    private let present: Set<String> = [
        "/work/admiral/App/Sources/Views/ChatView.swift",
        "/work/notes.md",
        "/Users/me/code/test/main.swift",
    ]
    private func detect(_ text: String) -> [ChatLink] {
        ChatLinks.detect(in: text, cwd: cwd, fileExists: { present.contains($0) })
    }

    func testResolvesWorkspaceRelativeAndAbsolutePaths() {
        let text = "Fixed admiral/App/Sources/Views/ChatView.swift and /Users/me/code/test/main.swift."
        let links = detect(text)
        XCTAssertEqual(links.map(\.url.path),
                       ["/work/admiral/App/Sources/Views/ChatView.swift", "/Users/me/code/test/main.swift"])
        // The range covers the path itself — the sentence's full stop stays plain text.
        let first = links[0]
        let start = text.index(text.startIndex, offsetBy: first.offset)
        let end = text.index(start, offsetBy: first.length)
        XCTAssertEqual(String(text[start..<end]), "admiral/App/Sources/Views/ChatView.swift")
        let second = links[1]
        let secondStart = text.index(text.startIndex, offsetBy: second.offset)
        XCTAssertEqual(String(text[secondStart..<text.index(secondStart, offsetBy: second.length)]),
                       "/Users/me/code/test/main.swift")
    }

    /// `file:52` opens at line 52, and the line rides in the highlighted range.
    func testCarriesALineNumber() {
        let links = detect("see notes.md:52 for the rest")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].line, 52)
        XCTAssertEqual(links[0].url.path, "/work/notes.md")
        XCTAssertEqual(links[0].length, "notes.md:52".count)
        XCTAssertEqual(detect("notes.md:52:7 column too").first?.line, 52)
    }

    /// The filesystem is the filter: prose and paths that don't exist stay plain text.
    func testOnlyRealFilesBecomeLinks() {
        XCTAssertTrue(detect("it improved by 3.5% e.g. a lot").isEmpty)
        XCTAssertTrue(detect("src/Nope.swift was never written").isEmpty)
        XCTAssertTrue(detect("notes.md").isEmpty == false, "a bare existing file still links")
    }

    func testPeelsMarkdownAndProseWrappers() {
        for text in ["`notes.md`", "(notes.md)", "**notes.md**", "\"notes.md\",", "notes.md;",
                     // A sentence's full stop outside the wrapper: the reply that would not open.
                     "`notes.md`.", "(notes.md).", "**notes.md**.", "`notes.md`:"] {
            let links = detect(text)
            XCTAssertEqual(links.count, 1, text)
            XCTAssertEqual(links.first?.url.path, "/work/notes.md", text)
            guard let link = links.first else { continue }
            let start = text.index(text.startIndex, offsetBy: link.offset)
            XCTAssertEqual(String(text[start..<text.index(start, offsetBy: link.length)]), "notes.md", text)
        }
    }

    /// A cited line survives the sentence it ends: `notes.md:52`. still opens at 52.
    func testALineNumberBeforeAFullStopIsKept() {
        for text in ["see `notes.md:52`.", "see notes.md:52.", "(notes.md:52)."] {
            let links = detect(text)
            XCTAssertEqual(links.count, 1, text)
            XCTAssertEqual(links.first?.line, 52, text)
            XCTAssertEqual(links.first?.length, "notes.md:52".count, text)
        }
    }

    func testNoCwdMeansNoLinks() {
        XCTAssertTrue(ChatLinks.detect(in: "notes.md", cwd: "", fileExists: { _ in true }).isEmpty)
    }

    /// Agents quote URLs in backticks (tables especially); the markdown parser links a bare URL
    /// but never one in a code span. Only a span that is exactly one web URL becomes a link.
    func testACodeSpanThatIsExactlyAWebURLIsALink() {
        XCTAssertEqual(ChatLinks.codeSpanURL("http://localhost:3000/orders/1042"),
                       URL(string: "http://localhost:3000/orders/1042"))
        XCTAssertEqual(ChatLinks.codeSpanURL(" https://example.com/a?b=1 "),
                       URL(string: "https://example.com/a?b=1"))
        XCTAssertNil(ChatLinks.codeSpanURL("npm test"))
        XCTAssertNil(ChatLinks.codeSpanURL("see https://example.com"))
        XCTAssertNil(ChatLinks.codeSpanURL("http://"))
        XCTAssertNil(ChatLinks.codeSpanURL("ftp://example.com/x"))
        XCTAssertNil(ChatLinks.codeSpanURL("mailto:someone@example.com"))
        XCTAssertNil(ChatLinks.codeSpanURL("src/api/users.ts"))
    }
}
