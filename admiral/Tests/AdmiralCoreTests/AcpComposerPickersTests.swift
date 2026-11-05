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
        XCTAssertEqual(decoded.update, .availableCommands([
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
}
