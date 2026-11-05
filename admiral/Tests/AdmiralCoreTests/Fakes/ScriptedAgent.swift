import XCTest
@testable import AdmiralCore

/// A scripted ACP agent: each request the client sends is answered by method, synchronously,
/// from inside `send` — so a test reads as "the agent says X to Y" with no timing. A handler
/// returning nil holds the request (a `session/prompt` in flight) until the test ends it.
final class ScriptedAgent: AcpTransport, @unchecked Sendable {
    enum Reply { case result(JSONValue), error(Int, String), hold }

    let fake = FakeAcpTransport()
    private let lock = NSLock()
    private var handlers: [String: (JSONValue) -> Reply] = [:]
    private var held: [(id: JSONValue, method: String)] = []

    init(capabilities: JSONValue = .object([:])) {
        on("initialize") { _ in .result(.object(["agentCapabilities": capabilities])) }
        on("session/new") { _ in .result(.object(["sessionId": .string("s1")])) }
        on("session/resume") { p in .result(.object(["sessionId": p["sessionId"] ?? .null])) }
        on("session/load") { _ in .result(.null) }
        on("session/fork") { _ in .result(.object(["sessionId": .string("s2")])) }
        on("session/set_mode") { _ in .result(.object([:])) }
        on("session/set_config_option") { _ in .result(.object([:])) }
        on("session/close") { _ in .result(.object([:])) }
        on("_session/steering") { _ in .result(.object([:])) }
        on("session/prompt") { _ in .hold }
    }

    func on(_ method: String, _ handler: @escaping (JSONValue) -> Reply) {
        lock.withLock { handlers[method] = handler }
    }

    // MARK: AcpTransport

    var lines: AsyncStream<String> { fake.lines }
    func terminate() { fake.terminate() }

    func send(line: String) throws {
        try fake.send(line: line)
        let msg = Self.json(line)
        guard let method = msg["method"]?.stringValue, let id = msg["id"] else { return }
        let reply = lock.withLock { handlers[method] }?(msg["params"] ?? .null) ?? .error(-32601, "nope")
        switch reply {
        case let .result(r): respond(id: id, result: r)
        case let .error(code, message): respond(id: id, error: (code, message))
        case .hold: lock.withLock { held.append((id, method)) }
        }
    }

    // MARK: Driving the agent

    /// Ends the oldest held `session/prompt`.
    func endPrompt(_ stopReason: String = "end_turn") {
        let entry = lock.withLock { () -> (id: JSONValue, method: String)? in
            guard let i = held.firstIndex(where: { $0.method == "session/prompt" }) else { return nil }
            return held.remove(at: i)
        }
        guard let entry else { return XCTFail("no prompt in flight") }
        respond(id: entry.id, result: .object(["stopReason": .string(stopReason)]))
    }

    /// Ends the oldest held `session/prompt` with a JSON-RPC error.
    func failPrompt(code: Int = -32603, message: String = "boom") {
        let entry = lock.withLock { () -> (id: JSONValue, method: String)? in
            guard let i = held.firstIndex(where: { $0.method == "session/prompt" }) else { return nil }
            return held.remove(at: i)
        }
        guard let entry else { return XCTFail("no prompt in flight") }
        respond(id: entry.id, error: (code, message))
    }

    var heldPrompts: Int { lock.withLock { held.filter { $0.method == "session/prompt" }.count } }

    func say(_ text: String, session: String = "s1") {
        feed([
            "jsonrpc": .string("2.0"), "method": .string("session/update"),
            "params": .object([
                "sessionId": .string(session),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(text)]),
                ]),
            ]),
        ])
    }

    func ask(id: String, method: String, params: JSONValue) {
        feed(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params])
    }

    // MARK: Reading what the client sent

    var messages: [JSONValue] { fake.sent.map(Self.json) }
    /// Methods of the client's requests and notifications, in order.
    var methods: [String] { messages.compactMap { $0["method"]?.stringValue } }
    func params(of method: String) -> [JSONValue] {
        messages.filter { $0["method"]?.stringValue == method }.compactMap { $0["params"] }
    }
    func prompts() -> [String] {
        params(of: "session/prompt").compactMap { $0["prompt"]?.arrayValue?.first?["text"]?.stringValue }
    }
    /// The client's reply to the agent's request `id`.
    func reply(to id: String) -> JSONValue? {
        messages.first { $0["method"] == nil && $0["id"]?.stringValue == id }
    }

    // MARK: -

    private func respond(id: JSONValue, result: JSONValue? = nil, error: (Int, String)? = nil) {
        var o: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
        if let error {
            o["error"] = .object(["code": .number(Double(error.0)), "message": .string(error.1)])
        } else {
            o["result"] = result ?? .null
        }
        feed(o)
    }

    private func feed(_ o: [String: JSONValue]) {
        fake.feed(String(decoding: try! JSONEncoder().encode(JSONValue.object(o)), as: UTF8.self))
    }

    static func json(_ line: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))) ?? .null
    }
}
