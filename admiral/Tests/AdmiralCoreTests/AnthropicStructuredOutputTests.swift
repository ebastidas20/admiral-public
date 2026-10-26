// Tests/AdmiralCoreTests/AnthropicStructuredOutputTests.swift
import XCTest
@testable import AdmiralCore

final class AnthropicStructuredOutputTests: XCTestCase {
    private func decode(_ s: String) -> AnthropicMessagesRequest? {
        AnthropicMessagesRequest.decode(Data(s.utf8))
    }
    private let base = #""model":"claude-opus-4-8","messages":[{"role":"user","content":"q"}]"#

    func testNoStructuredOutputFields() {
        let req = decode("{\(base)}")!
        XCTAssertNil(req.structuredOutput)
        XCTAssertNil(req.structuredOutputError)
    }

    func testOutputFormatJSONSchema() {
        let req = decode("""
        {\(base),"output_format":{"type":"json_schema","schema":{"type":"object","required":["ok"]}}}
        """)!
        XCTAssertEqual(req.structuredOutput?.delivery, .jsonText)
        XCTAssertNil(req.structuredOutput?.toolName)
        XCTAssertEqual(req.structuredOutput?.schema["required"]?.arrayValue?.first?.stringValue, "ok")
    }

    func testForcedToolChoice() {
        let req = decode("""
        {\(base),"tools":[{"name":"report","input_schema":{"type":"object"}}],
         "tool_choice":{"type":"tool","name":"report"}}
        """)!
        XCTAssertEqual(req.structuredOutput?.delivery, .toolUse)
        XCTAssertEqual(req.structuredOutput?.toolName, "report")
        XCTAssertNil(req.clientTools, "a forced tool_choice consumes tools as a schema")
    }

    func testToolsWithoutForcedChoiceIgnored() {
        let req = decode("""
        {\(base),"tools":[{"name":"report","description":"a report","input_schema":{"type":"object"}}],
         "tool_choice":{"type":"auto"}}
        """)!
        XCTAssertNil(req.structuredOutput)
        XCTAssertNil(req.structuredOutputError)
        XCTAssertEqual(req.clientTools?.map(\.name), ["report"])
        XCTAssertEqual(req.clientTools?.first?.description, "a report")
    }

    func testBothFormsIsAnError() {
        let req = decode("""
        {\(base),"output_format":{"type":"json_schema","schema":{"type":"object"}},
         "tools":[{"name":"report","input_schema":{"type":"object"}}],
         "tool_choice":{"type":"tool","name":"report"}}
        """)!
        XCTAssertNil(req.structuredOutput)
        XCTAssertEqual(req.structuredOutputError, "output_format and a forced tool_choice cannot be combined")
    }

    func testForcedChoiceNamingUnknownToolIsAnError() {
        let req = decode("""
        {\(base),"tools":[{"name":"other","input_schema":{"type":"object"}}],
         "tool_choice":{"type":"tool","name":"report"}}
        """)!
        XCTAssertNil(req.structuredOutput)
        XCTAssertEqual(req.structuredOutputError,
                       "tool_choice names 'report' but no such tool with an input_schema is in tools")
    }
}

@MainActor
final class AnthropicEndpointStructuredOutputTests: XCTestCase {
    private var backend: FakeAnthropicBackend!
    private var endpoint: AnthropicEndpoint!
    private var tabID: UUID!
    private var transcript: URL!

    private static let cfg = AnthropicEndpoint.Config(
        busyWaitTimeout: 0.05, busySeenTimeout: 0.03, turnTimeout: 0.3,
        pollInterval: 0.01, pingInterval: 10, structuredOutputGrace: 0.05,
        injectReadyTimeout: 0.05, injectVerifyTimeout: 0.02, injectMaxAttempts: 3)

    override func setUp() async throws {
        backend = FakeAnthropicBackend()
        endpoint = AnthropicEndpoint(backend: backend, config: Self.cfg)
        tabID = UUID()
        backend.tabs["Worker"] = AnthropicTab(id: tabID, name: "Worker", isManaged: true)
        transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("so-endpoint-\(UUID().uuidString).jsonl")
        try Data().write(to: transcript)
        backend.paths[tabID] = transcript.path
    }

    private func post(_ body: String, stream: Bool = false) async -> (status: Int, raw: String) {
        let request = HTTPRequest(method: "POST", path: "/v1/messages",
                                  headers: ["admiral_tab_name": "Worker", "x-api-key": "adm_so"], body: Data(body.utf8))
        var collected = Data()
        await endpoint.handle(request) { collected.append($0) }
        let text = String(data: collected, encoding: .utf8)!
        return (Int(text.split(separator: " ")[1])!, text)
    }
    private func appendTranscript(_ line: String) {
        let h = try! FileHandle(forWritingTo: transcript)
        h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try! h.close()
    }
    private var soBody: String {
        #"{"model":"m","messages":[{"role":"user","content":"go"}],"# +
        #""output_format":{"type":"json_schema","schema":{"type":"object","required":["ok"]}}}"#
    }
    private var toolBody: String {
        #"{"model":"m","messages":[{"role":"user","content":"go"}],"# +
        #""tools":[{"name":"report","input_schema":{"type":"object"}}],"tool_choice":{"type":"tool","name":"report"}}"#
    }
    private func fulfill(_ result: String) {
        var s = backend.soStates[tabID]!
        s.status = .fulfilled
        s.result = try! JSONDecoder().decode(JSONValue.self, from: Data(result.utf8))
        backend.soStates[tabID] = s
    }

    func testConflictingSOFieldsIs400() async {
        let body = #"{"model":"m","messages":[{"role":"user","content":"go"}],"# +
            #""output_format":{"type":"json_schema","schema":{"type":"object"}},"# +
            #""tools":[{"name":"r","input_schema":{"type":"object"}}],"tool_choice":{"type":"tool","name":"r"}}"#
        let r = await post(body)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(backend.armedSpecs.isEmpty)
    }

    func testFulfilledJSONTextResponse() async {
        backend.statuses = [.busy, .idle]
        backend.onPoll = { [self] n in if n == 1 { fulfill(#"{"ok":true}"#) } }
        let r = await post(soBody)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.raw.contains(#""stop_reason":"end_turn""#))
        XCTAssertTrue(r.raw.contains(#"{\"ok\":true}"# ) || r.raw.contains(#""ok":true"#), r.raw)
        XCTAssertEqual(backend.clearedSO, [tabID], "tripwire cleared on exit")
    }

    func testFulfilledToolUseResponse() async {
        backend.statuses = [.busy, .idle]
        backend.onPoll = { [self] n in if n == 1 { fulfill(#"{"ok":true}"#) } }
        let r = await post(toolBody)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.raw.contains(#""type":"tool_use""#), r.raw)
        XCTAssertTrue(r.raw.contains(#""name":"report""#))
        XCTAssertTrue(r.raw.contains(#""stop_reason":"tool_use""#))
    }

    func testFailedTripwireIs500() async {
        backend.statuses = [.busy, .idle]
        backend.onPoll = { [self] n in
            if n == 1 { var s = backend.soStates[tabID]!; s.status = .failed; backend.soStates[tabID] = s }
        }
        let r = await post(soBody)
        XCTAssertEqual(r.status, 500)
        XCTAssertTrue(r.raw.contains("structured output failed"))
    }

    func testHookNeverFiringBailsFastWith500() async {
        // Idle from the start, tripwire armed, blocks == 0: the grace bail must fire well
        // before turnTimeout. A wide cap keeps the two apart on a slow CI runner too (0.3s
        // against a 0.05s grace measured 0.29s there).
        var cfg = Self.cfg
        cfg.turnTimeout = 5
        endpoint = AnthropicEndpoint(backend: backend, config: cfg)
        backend.statuses = [.idle]
        let started = Date()
        let r = await post(soBody)
        XCTAssertEqual(r.status, 500)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "bailed at grace, not turnTimeout")
    }

    func testArmedButUnresolvedKeepsWaitingPastIdle() async {
        // busy→idle at poll 2, but the tripwire resolves only at poll 4 (a Stop block
        // kept the session going): the endpoint must NOT complete at the first idle.
        backend.statuses = [.busy, .idle, .idle, .idle]
        backend.onPoll = { [self] n in
            if n >= 2, backend.soStates[tabID]?.status == .armed {
                var s = backend.soStates[tabID]!
                s.blocks = 1                     // hook did fire — no grace bail
                if n == 4 { s.status = .fulfilled
                            s.result = try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"ok":true}"#.utf8)) }
                backend.soStates[tabID] = s
            }
        }
        let r = await post(soBody)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(r.raw.contains(#""stop_reason":"end_turn""#))
    }

    func testStreamingStructuredOutputEmitsSingleBlockAtEnd() async {
        backend.statuses = [.busy, .idle]
        backend.onPoll = { [self] n in
            if n == 1 {
                appendTranscript(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working…"}],"usage":{"input_tokens":1,"output_tokens":1}}}"#)
                fulfill(#"{"ok":true}"#)
            }
        }
        let body = soBody.replacingOccurrences(of: #""messages""#, with: #""stream":true,"messages""#)
        let r = await post(body)
        XCTAssertEqual(r.status, 200)
        XCTAssertFalse(r.raw.contains("working…"), "intermediate turn text is not the answer — never streamed")
        // The result rides a text_delta whose text value is JSON-string-escaped, exactly
        // as the non-streaming sibling test accepts it.
        XCTAssertTrue(r.raw.contains(#"{\"ok\":true}"#) || r.raw.contains(#""ok":true"#), r.raw)
        XCTAssertTrue(r.raw.contains("message_stop"))
    }
}
