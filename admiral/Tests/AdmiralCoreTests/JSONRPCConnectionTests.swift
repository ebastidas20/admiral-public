import XCTest
@testable import AdmiralCore

final class JSONRPCConnectionTests: XCTestCase {
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _v: [T] = []
        func add(_ t: T) { lock.withLock { _v.append(t) } }
        var values: [T] { lock.withLock { _v } }
    }

    private func make(
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> (FakeAcpTransport, JSONRPCConnection) {
        let t = FakeAcpTransport()
        let c = JSONRPCConnection(transport: t, log: log)
        await c.start()
        return (t, c)
    }

    private func json(_ line: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    func testRequestResolvesWithMatchingIdResult() async throws {
        let (t, c) = await make()
        async let r = c.request("ping", params: .object([:]))
        _ = await t.waitForSent(1)
        t.feed(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#)
        let result = try await r
        XCTAssertEqual(result, .object(["ok": .bool(true)]))
        let sent = try json(t.sent[0])
        XCTAssertEqual(sent["method"]?.stringValue, "ping")
        XCTAssertEqual(sent["jsonrpc"]?.stringValue, "2.0")
    }

    func testErrorResponseThrowsJSONRPCError() async throws {
        let (t, c) = await make()
        async let r = c.request("x", params: .null)
        _ = await t.waitForSent(1)
        t.feed(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"x"}}"#)
        do {
            _ = try await r
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, JSONRPCError(code: -32601, message: "x"))
        }
    }

    func testOutOfOrderResponsesResolveTheRightCallers() async throws {
        let (t, c) = await make()
        async let a = c.request("a", params: .null)
        _ = await t.waitForSent(1)
        async let b = c.request("b", params: .null)
        _ = await t.waitForSent(2)
        t.feed(#"{"jsonrpc":"2.0","id":2,"result":"second"}"#)
        t.feed(#"{"jsonrpc":"2.0","id":1,"result":"first"}"#)
        let (ra, rb) = try await (a, b)
        XCTAssertEqual(ra, .string("first"))
        XCTAssertEqual(rb, .string("second"))
    }

    func testInboundRequestHandlerReplyIsSentWithSameId() async throws {
        let (t, c) = await make()
        await c.onRequest { method, _ in
            XCTAssertEqual(method, "session/request_permission")
            return .object(["outcome": .string("ok")])
        }
        t.feed(#"{"jsonrpc":"2.0","id":"a","method":"session/request_permission","params":{}}"#)
        let sent = await t.waitForSent(1)
        let reply = try json(sent[0])
        XCTAssertEqual(reply["id"], .string("a"))
        XCTAssertEqual(reply["result"], .object(["outcome": .string("ok")]))
    }

    func testInboundNumericIdIsEchoedAsNumber() async throws {
        let (t, c) = await make()
        await c.onRequest { _, _ in .null }
        t.feed(#"{"jsonrpc":"2.0","id":7,"method":"m"}"#)
        let sent = await t.waitForSent(1)
        XCTAssertEqual(try json(sent[0])["id"], .number(7))
    }

    func testInboundRequestWithoutHandlerGetsMethodNotFound() async throws {
        let (t, c) = await make()
        t.feed(#"{"jsonrpc":"2.0","id":5,"method":"nope","params":{}}"#)
        let sent = await t.waitForSent(1)
        withExtendedLifetime(c) {}
        let reply = try json(sent[0])
        XCTAssertEqual(reply["id"], .number(5))
        XCTAssertEqual(reply["error"]?["code"], .number(-32601))
    }

    func testHandlerThrowingJSONRPCErrorBecomesErrorReply() async throws {
        let (t, c) = await make()
        await c.onRequest { _, _ in throw JSONRPCError(code: -32602, message: "bad") }
        t.feed(#"{"jsonrpc":"2.0","id":1,"method":"m"}"#)
        let sent = await t.waitForSent(1)
        let reply = try json(sent[0])
        XCTAssertEqual(reply["error"]?["code"], .number(-32602))
        XCTAssertEqual(reply["error"]?["message"]?.stringValue, "bad")
    }

    func testNotificationReachesHandler() async throws {
        let (t, c) = await make()
        let got = Box<String>()
        let exp = expectation(description: "notification")
        await c.onNotification { method, params in
            got.add("\(method)|\(params["k"]?.stringValue ?? "")")
            exp.fulfill()
        }
        t.feed(#"{"jsonrpc":"2.0","method":"session/update","params":{"k":"v"}}"#)
        await fulfillment(of: [exp], timeout: 5)
        XCTAssertEqual(got.values, ["session/update|v"])
    }

    func testNonJSONLineIsSkippedAndLogged() async throws {
        let logged = Box<String>()
        let (t, c) = await make(log: { logged.add($0) })
        t.feed("npx: installed 1 package")
        async let r = c.request("ping", params: .null)
        _ = await t.waitForSent(1)
        t.feed(#"{"jsonrpc":"2.0","id":1,"result":1}"#)
        let result = try await r
        XCTAssertEqual(result, .number(1))
        XCTAssertTrue(logged.values.contains { $0.contains("npx: installed 1 package") })
    }

    func testCloseFailsPendingRequests() async throws {
        let (t, c) = await make()
        let closed = expectation(description: "onClose")
        await c.onClose { closed.fulfill() }
        async let r = c.request("ping", params: .null)
        _ = await t.waitForSent(1)
        t.finish()
        do {
            _ = try await r
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .closed)
        }
        await fulfillment(of: [closed], timeout: 5)
        do {
            _ = try await c.request("again", params: .null)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, .closed)
        }
    }

    func testCloseTerminatesTransport() async throws {
        let (t, c) = await make()
        await c.close()
        XCTAssertTrue(t.terminated)
    }

    func testSentLinesAreSingleLineJSON() async throws {
        let (t, c) = await make()
        try await c.notify("n", params: .object(["text": .string("a\nb\r\nc")]))
        async let r = c.request("q", params: .object(["t": .string("x\ny")]))
        _ = await t.waitForSent(2)
        t.feed(#"{"jsonrpc":"2.0","id":1,"result":null}"#)
        _ = try await r
        for line in t.sent {
            XCTAssertFalse(line.contains("\n"))
            XCTAssertFalse(line.contains("\r"))
            _ = try json(line)
        }
    }

    func testOutOfRangeIdAndErrorCodeDoNotCrashTheConnection() async throws {
        let logged = Box<String>()
        let (t, c) = await make(log: { logged.add($0) })
        t.feed(#"{"jsonrpc":"2.0","id":1e300,"result":0}"#)
        async let r = c.request("ping", params: .null)
        _ = await t.waitForSent(1)
        t.feed(#"{"jsonrpc":"2.0","id":1,"error":{"code":1e20,"message":"big"}}"#)
        do {
            _ = try await r
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, JSONRPCError(code: -32603, message: "big"))
        }
        XCTAssertTrue(logged.values.contains { $0.contains("unmatched") })
        async let r2 = c.request("again", params: .null)
        _ = await t.waitForSent(2)
        t.feed(#"{"jsonrpc":"2.0","id":2,"result":"alive"}"#)
        let alive = try await r2
        XCTAssertEqual(alive, .string("alive"))
    }

    /// The ACP log holds the traffic, with the session bridge's bearer masked and long lines cut.
    func testTracedLinesMaskBearerAndAreCapped() {
        let line = #"{"headers":[{"name":"Authorization","value":"Bearer s3cr3t-token"}]}"#
        XCTAssertEqual(JSONRPCConnection.traced("->", line),
                       #"acp: -> {"headers":[{"name":"Authorization","value":"Bearer ***"}]}"#)
        let long = String(repeating: "a", count: 5_000)
        XCTAssertEqual(JSONRPCConnection.traced("<-", long).count, "acp: <- ".count + JSONRPCConnection.traceLimit + 1)
    }
}
