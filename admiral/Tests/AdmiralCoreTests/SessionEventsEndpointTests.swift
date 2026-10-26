import XCTest
@testable import AdmiralCore

@MainActor
private final class FakeFeedSource: SessionFeedSource {
    let tabID = UUID()
    /// One (status, turns) per poll; the last one repeats for a while, then the tab "closes"
    /// — so a stream that never sends what a test waits for ends (and the test fails)
    /// instead of hanging.
    var polls: [(SessionStatus, [Turn])]
    private var index = 0
    private var current: (SessionStatus, [Turn]) { polls[min(index, polls.count - 1)] }

    init(_ polls: [(SessionStatus, [Turn])]) { self.polls = polls }

    func feedTab(callsign: String) -> (id: UUID, name: String)? {
        callsign == "scout" ? (tabID, "scout") : nil
    }
    func feedStatus(tabID: UUID) -> SessionStatus? { index > polls.count + 20 ? nil : current.0 }
    func feedTurns(tabID: UUID) async -> [Turn] {
        defer { index += 1 }
        return current.1
    }
    var output: StructuredOutputState?
    func feedOutput(tabID: UUID) -> StructuredOutputState? { output }
    var redacted: [RedactedOutput]?
    func feedRedactedOutput(tabID: UUID) -> [RedactedOutput]? { redacted }
}

@MainActor
final class SessionEventsEndpointTests: XCTestCase {
    private let prompt = Turn.user(id: "1", text: "fix it")
    private let reply = Turn.assistant(id: "2", markdown: "fixed", model: nil)

    private func request(_ path: String = "/sessions/scout/events", method: String = "GET",
                         token: String? = "secret", lastEventID: String? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["authorization"] = "Bearer \(token)" }
        if let lastEventID { headers["last-event-id"] = lastEventID }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data())
    }

    /// Runs the stream until `stopAfter` matches a written chunk; the "client" hangs up on
    /// that write (it returns false), which is what ends the loop.
    private func stream(_ source: FakeFeedSource, _ req: HTTPRequest,
                        stopAfter: @escaping (String) -> Bool) async -> String {
        let endpoint = SessionEventsEndpoint(source: source, pollInterval: 0.001, pingInterval: 60)
        var out = ""
        await endpoint.handle(req) { data in
            let chunk = String(decoding: data, as: UTF8.self)
            out += chunk
            return !stopAfter(chunk)
        }
        return out
    }

    func testStreamsWithoutAnOperatorToken() async {
        let out = await stream(FakeFeedSource([(.idle, [])]), request(token: nil)) { _ in true }
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200"), out)
        XCTAssertTrue(out.contains("text/event-stream"), out)
        let wrong = await stream(FakeFeedSource([(.idle, [])]), request(token: "nope")) { _ in true }
        XCTAssertTrue(wrong.hasPrefix("HTTP/1.1 200"), wrong)
        XCTAssertTrue(wrong.contains("text/event-stream"), wrong)
    }

    /// A browser page (Origin) or a DNS-rebound hostname is refused. Loopback needs no token.
    func testBrowserOriginatedRequestIsRefused403() async {
        for extra in [["origin": "https://evil.example"], ["host": "evil.example:4141"]] {
            var req = request()
            req = HTTPRequest(method: req.method, path: req.path,
                              headers: req.headers.merging(extra) { a, _ in a }, body: req.body)
            let out = await stream(FakeFeedSource([(.idle, [])]), req) { _ in true }
            XCTAssertTrue(out.hasPrefix("HTTP/1.1 403"), out)
            XCTAssertFalse(out.contains("text/event-stream"))
        }
        let loopback = HTTPRequest(method: "GET", path: "/sessions/scout/events",
                                   headers: ["host": "127.0.0.1:4141"], body: Data())
        let ok = await stream(FakeFeedSource([(.idle, [])]), loopback) { _ in true }
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200"), ok)
    }

    func testUnknownSessionAndWrongMethod() async {
        let missing = await stream(FakeFeedSource([(.idle, [])]), request("/sessions/ghost/events")) { _ in true }
        XCTAssertTrue(missing.hasPrefix("HTTP/1.1 404"), missing)
        let post = await stream(FakeFeedSource([(.idle, [])]), request(method: "POST")) { _ in true }
        XCTAssertTrue(post.hasPrefix("HTTP/1.1 405"), post)
    }

    /// A message appended to the transcript reaches the follower as an SSE frame, and the
    /// turn ending sends the stop with that reply.
    func testStreamsNewMessageThenStop() async {
        let source = FakeFeedSource([(.busy, [prompt]), (.busy, [prompt]), (.idle, [prompt, reply])])
        let out = await stream(source, request()) { $0.contains("event: stop") }
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream"), out)
        XCTAssertTrue(out.contains("event: hello\ndata: {\"callsign\":\"scout\",\"status\":\"busy\"}"), out)
        XCTAssertTrue(out.contains("id: a-2\nevent: message\ndata: {\"text\":\"fixed\"}\n\n"), out)
        XCTAssertTrue(out.contains("id: a-2#stop\nevent: stop\ndata: {\"text\":\"fixed\"}\n\n"), out)
        XCTAssertFalse(out.contains("event: prompt"), "the prompt was history at connect")
    }

    /// A failed round goes out with when it failed, why, the turn it follows and the callsign.
    func testStreamsTheOutputEventWithItsDetail() async throws {
        let source = FakeFeedSource([(.idle, [prompt, reply])])
        source.output = StructuredOutputState(
            schema: .object([:]), delivery: .jsonText, status: .failed, round: 2,
            completedAt: Date(timeIntervalSince1970: 1_790_000_000),
            violations: ["no output after 3 blocks"])
        let out = await stream(source, request(lastEventID: "u-1")) { $0.contains("event: output") }
        XCTAssertTrue(out.contains(#"event: output"#), out)
        XCTAssertTrue(out.contains(#"data: {"at":"2026-09-21T"#), out)
        XCTAssertTrue(out.contains(#""callsign":"scout","redacted":false,"result":null,"round":2,"status":"failed","turn":"a-2","violations":["no output after 3 blocks"]}"#), out)
    }

    func testLastEventIDHeaderResumesInsteadOfReplaying() async {
        let source = FakeFeedSource([(.busy, [prompt, reply])])
        let out = await stream(source, request(lastEventID: "u-1")) { $0.contains("event: message") }
        XCTAssertTrue(out.contains("id: a-2\nevent: message"), out)
        XCTAssertFalse(out.contains("event: prompt"), "u-1 was already seen")
    }

    /// With redaction on, the round reaches the wire only once the mod's copy exists, carrying
    /// the copy — the slot's raw result is never written. Obviously fake test data.
    func testRedactedRoundIsStreamedFromTheCopyOnly() async {
        let source = FakeFeedSource([(.busy, [prompt]), (.idle, [prompt, reply])])
        source.output = StructuredOutputState(
            schema: .object([:]), delivery: .toolUse, status: .fulfilled,
            result: .object(["slack_reply": .string("filed for John Testerston")]), round: 1)
        source.redacted = []
        let out = await stream(source, request(lastEventID: "u-1")) { chunk in
            if chunk.contains("event: stop") {
                source.redacted = [RedactedOutput(
                    round: 1, status: .fulfilled, result: .object(["slack_reply": .string("filed for [REDACTED]")]))]
            }
            return chunk.contains("event: output")
        }
        XCTAssertTrue(out.contains(
            #"id: a-2~o1"# + "\nevent: output\n" + #"data: {"at":null,"callsign":"scout","redacted":true,"result":{"slack_reply":"filed for [REDACTED]"},"round":1,"status":"fulfilled","turn":"a-2","violations":[]}"#),
            out)
        XCTAssertFalse(out.contains("Testerston"), out)
    }

    func testClosedTabEndsTheStream() async {
        final class Gone: SessionFeedSource {
            var polls = 0
            func feedTab(callsign: String) -> (id: UUID, name: String)? { (UUID(), "scout") }
            func feedStatus(tabID: UUID) -> SessionStatus? { polls == 0 ? .idle : nil }
            func feedTurns(tabID: UUID) async -> [Turn] { polls += 1; return [] }
            func feedOutput(tabID: UUID) -> StructuredOutputState? { nil }
            func feedRedactedOutput(tabID: UUID) -> [RedactedOutput]? { nil }
        }
        let endpoint = SessionEventsEndpoint(source: Gone(), pollInterval: 0.001)
        var out = ""
        await endpoint.handle(request()) { out += String(decoding: $0, as: UTF8.self); return true }
        XCTAssertTrue(out.hasSuffix("event: closed\ndata: {}\n\n"), out)
    }

    func testPathParsing() {
        XCTAssertEqual(SessionEventsEndpoint.callsign(inPath: "/sessions/scout/events"), "scout")
        XCTAssertEqual(SessionEventsEndpoint.callsign(inPath: "/sessions/night%20shift/events?x=1"), "night shift")
        XCTAssertNil(SessionEventsEndpoint.callsign(inPath: "/sessions/scout"))
        XCTAssertNil(SessionEventsEndpoint.callsign(inPath: "/mcp"))
    }
}
