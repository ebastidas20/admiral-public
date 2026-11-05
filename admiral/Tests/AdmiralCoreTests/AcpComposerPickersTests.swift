import XCTest
@testable import AdmiralCore

final class AcpComposerPickersTests: XCTestCase {
    private let commands = [
        AcpCommandInfo(name: "init", description: "Init a project"),
        AcpCommandInfo(name: "review", description: "Review the web diff"),
        AcpCommandInfo(name: "web", description: "Search", hint: "query"),
        AcpCommandInfo(name: "sweb", description: "x")
    ]

    func testDecodesAvailableCommandsWithHint() throws {
        let json = #"""
        {"sessionId":"s","update":{"sessionUpdate":"available_commands_update","availableCommands":[
        {"name":"web","description":"Search","input":{"hint":"query"}},{"name":"init","description":"Init"}]}}
        """#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let decoded = try XCTUnwrap(AcpUpdate.decode(value))
        XCTAssertEqual(decoded.updates.first, .availableCommands([
            AcpCommandInfo(name: "web", description: "Search", hint: "query"),
            AcpCommandInfo(name: "init", description: "Init", hint: nil)
        ]))
    }

    func testQuery() {
        XCTAssertEqual(SlashCommandPicker.query(in: "/we"), "we")
        XCTAssertEqual(SlashCommandPicker.query(in: "/"), "")
        XCTAssertNil(SlashCommandPicker.query(in: "/web x"))
        XCTAssertNil(SlashCommandPicker.query(in: "a /we"))
        XCTAssertNil(SlashCommandPicker.query(in: ""))
    }

    func testCandidatesPrefixThenSubstringInAgentOrder() {
        XCTAssertEqual(SlashCommandPicker.candidates("we", commands: commands).map(\.name), ["web", "review", "sweb"])
        XCTAssertEqual(SlashCommandPicker.candidates("WEB", commands: commands).map(\.name), ["web", "review", "sweb"])
        XCTAssertEqual(SlashCommandPicker.candidates("", commands: commands).map(\.name), commands.map(\.name))
        XCTAssertTrue(SlashCommandPicker.candidates("zzz", commands: commands).isEmpty)
    }

    func testInsert() {
        XCTAssertEqual(SlashCommandPicker.insert(commands[2]), "/web ")
    }

    // MARK: - @file

    private let files = ["src/a.swift", "src/lib/data.swift", "docs/a b.md", "README.md", "app/src/Main.swift"]

    func testFileQuery() {
        XCTAssertEqual(FileMentionPicker.query(in: "see @src/a"), FileMentionPicker.Query(offset: 4, partial: "src/a"))
        XCTAssertEqual(FileMentionPicker.query(in: "@"), FileMentionPicker.Query(offset: 0, partial: ""))
        XCTAssertEqual(FileMentionPicker.query(in: "x (@do"), FileMentionPicker.Query(offset: 3, partial: "do"))
        XCTAssertNil(FileMentionPicker.query(in: "a@b"))
        XCTAssertNil(FileMentionPicker.query(in: "@src/a "))
        XCTAssertNil(FileMentionPicker.query(in: "plain"))
    }

    func testFileCandidatesBasenamePrefixThenPathSubstring() {
        XCTAssertEqual(FileMentionPicker.candidates("a", files: files),
                       ["src/a.swift", "docs/a b.md", "src/lib/data.swift", "README.md", "app/src/Main.swift"])
        XCTAssertEqual(FileMentionPicker.candidates("SRC/", files: files),
                       ["src/a.swift", "src/lib/data.swift", "app/src/Main.swift"])
        XCTAssertEqual(FileMentionPicker.candidates("", files: files), files)
        XCTAssertEqual(FileMentionPicker.candidates("", files: (0..<80).map { "f\($0)" }).count, 50)
        XCTAssertTrue(FileMentionPicker.candidates("zzz", files: files).isEmpty)
    }

    func testFileInsert() {
        let text = "see @src/a"
        let q = try! XCTUnwrap(FileMentionPicker.query(in: text))
        XCTAssertEqual(FileMentionPicker.insert("src/a.swift", into: text, at: q), "see @src/a.swift ")
    }

    func testMentionsOnlyKnownFilesInOrderDeduped() {
        let known = Set(files)
        let text = "fix @src/a.swift and @docs/a b.md, not @nope.txt or me@src/a.swift; again @src/a.swift."
        XCTAssertEqual(FileMentionPicker.mentions(in: text, files: known), ["src/a.swift", "docs/a b.md"])
        XCTAssertEqual(FileMentionPicker.mentions(in: "no mentions", files: known), [])
    }

    func testResourceLinkNormalizesAndEncodes() {
        let link = AcpResourceLink(path: "src/a b.swift", cwd: "/p/./x/../")
        XCTAssertEqual(link.absolutePath, "/p/src/a b.swift")
        XCTAssertEqual(link.uri, "file:///p/src/a%20b.swift")
    }
}
