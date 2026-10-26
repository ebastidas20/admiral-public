import XCTest
@testable import AdmiralCore

@MainActor
final class AnthropicStreamingTests: XCTestCase {
    private var backend: FakeAnthropicBackend!
    private var endpoint: AnthropicEndpoint!
    private var tabID: UUID!
    private var transcript: URL!

    override func setUp() async throws {
        backend = FakeAnthropicBackend()
        endpoint = AnthropicEndpoint(backend: backend, config: .init(
            busyWaitTimeout: 0.05, busySeenTimeout: 0.03, turnTimeout: 0.2,
            pollInterval: 0.01, pingInterval: 10,
            injectReadyTimeout: 0.05, injectVerifyTimeout: 0.02, injectMaxAttempts: 3))
        tabID = UUID()
        backend.tabs["Worker"] = AnthropicTab(id: tabID, name: "Worker", isManaged: true)
        transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("sse-\(UUID().uuidString).jsonl")
        try Data().write(to: transcript)
        backend.paths[tabID] = transcript.path
    }

    private func appendAssistant(_ text: String, usage: (Int, Int) = (3, 9)) {
        let line = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}],\"usage\":{\"input_tokens\":\(usage.0),\"output_tokens\":\(usage.1)}}}\n"
        let handle = try! FileHandle(forWritingTo: transcript)
        handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try! handle.close()
    }

    /// Real claude echoes the submitted prompt into the transcript as a user line —
    /// simulate that so the endpoint's delivery verification sees the prompt land.
    private func echoUserLineOnInject() {
        backend.onInject = { [self] n in
            guard n == 1 else { return }
            let line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"echoed\"}}\n"
            let handle = try! FileHandle(forWritingTo: transcript)
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try! handle.close()
        }
    }

    /// Run a streaming request against `tab`, return the emitted chunks as strings.
    private func stream(_ body: String, tab: String = "Worker") async -> [String] {
        let request = HTTPRequest(method: "POST", path: "/v1/messages",
                                  headers: ["admiral_tab_name": tab, "x-api-key": "adm_sse"], body: Data(body.utf8))
        var chunks: [String] = []
        await endpoint.handle(request) { chunks.append(String(data: $0, encoding: .utf8) ?? "") }
        return chunks
    }
    private func eventTypes(_ chunks: [String]) -> [String] {
        chunks.joined().components(separatedBy: "event: ").dropFirst().map {
            String($0.prefix(while: { $0 != "\n" }))
        }
    }

    /// Parse every SSE frame's `data:` JSON into an object. Frames are separated by
    /// "\n\n" and shaped `event: <name>\ndata: <json>`. `JSONSerialization` (used by
    /// `AnthropicWire`) does not guarantee dictionary key order, so assertions must read
    /// parsed fields — never substring-match the raw JSON text. A parse failure fails
    /// the test loudly via XCTFail rather than being swallowed.
    private func parsedDataObjects(_ chunks: [String]) -> [[String: Any]] {
        let joined = chunks.joined()
        return joined.components(separatedBy: "\n\n").compactMap { frame -> [String: Any]? in
            guard let dataRange = frame.range(of: "data: ") else { return nil }
            let jsonText = String(frame[dataRange.upperBound...])
            guard !jsonText.isEmpty else { return nil }
            guard let jsonData = jsonText.data(using: .utf8) else {
                XCTFail("SSE frame data was not valid UTF-8: \(jsonText)")
                return nil
            }
            do {
                guard let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                    XCTFail("SSE frame data did not parse to a JSON object: \(jsonText)")
                    return nil
                }
                return obj
            } catch {
                XCTFail("Failed to parse SSE frame data JSON \(jsonText): \(error)")
                return nil
            }
        }
    }

    func testStreamingEmitsCanonicalEventSequence() async {
        backend.statuses = [.idle, .busy, .busy, .idle]
        echoUserLineOnInject()
        backend.onPoll = { [self] n in
            if n == 2 { appendAssistant("hello") }
            if n == 3 { appendAssistant(" world", usage: (5, 11)) }
        }
        let chunks = await stream("{\"model\":\"claude-opus-4-8\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")

        XCTAssertTrue(chunks.first?.hasPrefix("HTTP/1.1 200 OK") ?? false)
        XCTAssertTrue(chunks.first?.contains("text/event-stream") ?? false)
        let types = eventTypes(chunks)
        XCTAssertEqual(types.first, "message_start")
        XCTAssertEqual(types[1], "content_block_start")
        XCTAssertTrue(types.contains("content_block_delta"))
        XCTAssertEqual(Array(types.suffix(3)), ["content_block_stop", "message_delta", "message_stop"])

        // Deltas concatenate (with the blank-line join) to the full text. Note the
        // second chunk is "world", not " world" — capture trims each line's text.
        let dataObjects = parsedDataObjects(chunks)
        let deltaTexts = dataObjects
            .filter { ($0["type"] as? String) == "content_block_delta" }
            .compactMap { ($0["delta"] as? [String: Any])?["text"] as? String }
        XCTAssertEqual(deltaTexts.joined(), "hello\n\nworld")
        // final usage rides message_delta
        let messageDeltaUsage = dataObjects
            .first { ($0["type"] as? String) == "message_delta" }
            .flatMap { ($0["usage"] as? [String: Any])?["output_tokens"] as? Int }
        XCTAssertEqual(messageDeltaUsage, 11)
    }

    func testStreamingValidationErrorIsPlainHTTP() async {
        let body = "{\"model\":\"claude-opus-4-8\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"x\"}]}"
        let chunks = await stream(body, tab: "ghost")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasPrefix("HTTP/1.1 404"))
        XCTAssertFalse(chunks[0].contains("event:"))
    }
}
