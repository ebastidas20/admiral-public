import XCTest
@testable import AdmiralCore

final class AcpMessagesTests: XCTestCase {
    private func json(_ s: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    func testInitializeParamsAdvertiseExactlyElicitationCompactionTerminalOutput() {
        let p = AcpClient.initializeParams()
        XCTAssertEqual(p["protocolVersion"], .number(1))
        XCTAssertEqual(p["clientInfo"]?["name"]?.stringValue, "Admiral")
        guard case let .object(caps)? = p["clientCapabilities"] else { return XCTFail("no caps") }
        XCTAssertEqual(Set(caps.keys), ["elicitation", "session", "_meta"])
        XCTAssertNil(caps["fs"])
        XCTAssertNil(caps["terminal"])
        XCTAssertEqual(
            p["clientCapabilities"],
            json(#"{"elicitation":{"form":{}},"session":{"compaction":{}},"_meta":{"terminal_output":true}}"#))
    }

    func testCapabilitiesFromClaudeAgentAcpInitialize() {
        let r = json("""
        {"protocolVersion":1,"agentCapabilities":{"loadSession":true,
         "sessionCapabilities":{"fork":{},"list":{},"resume":{},"close":{}},
         "mcpCapabilities":{"http":true},"_meta":{"steering":{"supported":true}}},
         "agentInfo":{"name":"claude-agent-acp","version":"0.100.0"}}
        """)
        let c = AcpCapabilities(initializeResult: r)
        XCTAssertTrue(c.loadSession && c.resume && c.fork && c.list && c.close)
        XCTAssertTrue(c.mcpHTTP)
        XCTAssertTrue(c.steering)
        XCTAssertEqual(c.agentName, "claude-agent-acp")
        XCTAssertEqual(c.agentVersion, "0.100.0")
    }

    func testCapabilitiesDefaultFalseWhenAbsent() {
        let c = AcpCapabilities(initializeResult: json("{}"))
        XCTAssertFalse(c.loadSession || c.resume || c.fork || c.list || c.close || c.mcpHTTP || c.steering)
        XCTAssertNil(c.agentName)
        XCTAssertNil(c.agentVersion)
    }

    func testMCPServerEncodesHTTPWithBearerHeader() {
        let s = AcpMCPServer(name: "admiral", url: "http://h:4142/mcp", bearer: "tok")
        XCTAssertEqual(s.json, json("""
        {"type":"http","name":"admiral","url":"http://h:4142/mcp",
         "headers":[{"name":"Authorization","value":"Bearer tok"}]}
        """))
        let p = AcpClient.newSessionParams(cwd: "/w", mcpServers: [s])
        XCTAssertEqual(p["cwd"]?.stringValue, "/w")
        XCTAssertEqual(p["mcpServers"]?.arrayValue?.count, 1)
    }

    func testRequestParamsShapes() {
        let l = AcpClient.loadOrResumeParams(sessionID: "s1", cwd: "/w", mcpServers: [])
        XCTAssertEqual(l, json(#"{"sessionId":"s1","cwd":"/w","mcpServers":[]}"#))
        let p = AcpClient.promptParams(sessionID: "s1", text: "hi")
        XCTAssertEqual(p, json(#"{"sessionId":"s1","prompt":[{"type":"text","text":"hi"}]}"#))
        let st = AcpClient.steeringParams(sessionID: "s1", text: "hi")
        XCTAssertEqual(st["_meta"]?["idleBehavior"]?.stringValue, "promptRequired")
        XCTAssertEqual(st["prompt"], p["prompt"])
    }

    private func decode(_ update: String) -> AcpUpdate? {
        AcpUpdate.decode(json(#"{"sessionId":"S","update":\#(update)}"#))?.update
    }

    func testDecodeEachUpdateKind() {
        let chunk = #""content":{"type":"text","text":"hey"}"#
        XCTAssertEqual(decode(#"{"sessionUpdate":"agent_message_chunk",\#(chunk)}"#), .agentMessage("hey"))
        XCTAssertEqual(decode(#"{"sessionUpdate":"agent_thought_chunk",\#(chunk)}"#), .agentThought("hey"))
        XCTAssertEqual(decode(#"{"sessionUpdate":"user_message_chunk",\#(chunk)}"#), .userMessage("hey"))
        XCTAssertEqual(
            decode("""
            {"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read","kind":"read","status":"pending",
             "rawInput":{"p":1},"locations":[{"path":"/a"}]}
            """),
            .toolCall(id: "t1", title: "Read", kind: "read", status: "pending",
                      rawInput: .object(["p": .number(1)]), locations: ["/a"]))
        XCTAssertEqual(
            decode("""
            {"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed",
             "content":[{"type":"content","content":{"type":"text","text":"ok"}}],"locations":[{"path":"/b"}]}
            """),
            .toolCallUpdate(id: "t1", status: "completed", content: "ok", locations: ["/b"]))
        // claude-agent-acp sends a tool call's input on an update, not on the call (0.100.0).
        XCTAssertEqual(
            decode(#"{"sessionUpdate":"tool_call_update","toolCallId":"t1","rawInput":{"command":"ls"}}"#),
            .toolCallUpdate(id: "t1", status: nil, content: nil, locations: [],
                            rawInput: .object(["command": .string("ls")])))
        XCTAssertEqual(
            decode(#"{"sessionUpdate":"plan","entries":[{"content":"a","status":"pending","priority":"high"}]}"#),
            .plan([AcpPlanEntry(content: "a", status: "pending", priority: "high")]))
        XCTAssertEqual(
            decode(#"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"init"}]}"#),
            .availableCommands(["init"]))
        XCTAssertEqual(
            decode(#"{"sessionUpdate":"current_mode_update","currentModeId":"plan"}"#), .currentMode("plan"))
        XCTAssertEqual(decode(#"{"sessionUpdate":"compaction_update"}"#), .compaction)
        XCTAssertEqual(decode(#"{"sessionUpdate":"weird"}"#), .unknown("weird"))
        XCTAssertEqual(AcpUpdate.decode(json(#"{"sessionId":"S","update":{"sessionUpdate":"plan"}}"#))?.sessionID, "S")
        XCTAssertNil(AcpUpdate.decode(json("{}")))
    }

    func testStopReasonRawValues() {
        XCTAssertEqual(AcpStopReason(rawValue: "end_turn"), .endTurn)
    }
}
