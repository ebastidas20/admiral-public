import Foundation

public struct JSONRPCError: Error, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    /// Thrown to callers whose request was pending (or made) once the transport closed.
    public static let closed = JSONRPCError(code: -32000, message: "Connection closed")
}

/// JSON-RPC 2.0 over an `AcpTransport` (ndjson). Outgoing request ids are increasing Ints;
/// inbound request ids (number or string) are echoed back exactly as received.
public actor JSONRPCConnection {
    private let transport: AcpTransport
    private let log: @Sendable (String) -> Void
    /// Every line in (`acp: <-`) and out (`acp: ->`) also goes to `log` — the tab's ACP log.
    private let traceTraffic: Bool
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var requestHandler: (@Sendable (String, JSONValue) async throws -> JSONValue)?
    private var notificationHandler: (@Sendable (String, JSONValue) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var readTask: Task<Void, Never>?
    private var closed = false

    public init(transport: AcpTransport, traceTraffic: Bool = false, log: @escaping @Sendable (String) -> Void) {
        self.transport = transport
        self.traceTraffic = traceTraffic
        self.log = log
    }

    /// The longest traced line: a streamed chunk is small, but a tool result or a replayed
    /// history can be huge, and the log is read back by a view.
    static let traceLimit = 2_000

    /// A traced line: bearer tokens masked (the session bridge's rides on `session/new`), and
    /// cut at `traceLimit`. The `acp:` prefix keeps it out of `AcpLog.lastAgentLine`.
    static func traced(_ arrow: String, _ line: String) -> String {
        "acp: \(arrow) \(loggable(line))"
    }

    /// A wire line as it may go in the log: bearer tokens masked, cut at `traceLimit`. Every
    /// logged line from the agent passes through here — traced, non-JSON or unmatched.
    static func loggable(_ line: String) -> String {
        let masked = line.replacingOccurrences(
            of: #"Bearer [^"\\]+"#, with: "Bearer ***", options: .regularExpression)
        return masked.count > traceLimit ? String(masked.prefix(traceLimit)) + "\u{2026}" : masked
    }

    public func onRequest(_ handler: @escaping @Sendable (String, JSONValue) async throws -> JSONValue) {
        requestHandler = handler
    }

    public func onNotification(_ handler: @escaping @Sendable (String, JSONValue) -> Void) {
        notificationHandler = handler
    }

    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        closeHandler = handler
        if closed { handler() }
    }

    public func start() {
        guard readTask == nil else { return }
        let lines = transport.lines
        readTask = Task { [weak self] in
            for await line in lines { await self?.handle(line: line) }
            await self?.didClose()
        }
    }

    /// Terminates the transport; pending requests fail with `.closed` once the stream ends.
    public func close() {
        transport.terminate()
        didClose()
    }

    public func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        guard !closed else { throw JSONRPCError.closed }
        let id = nextId
        nextId += 1
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try write([
                    "jsonrpc": .string("2.0"), "id": .number(Double(id)),
                    "method": .string(method), "params": params,
                ])
            } catch {
                pending[id] = nil
                cont.resume(throwing: error)
            }
        }
    }

    public func notify(_ method: String, params: JSONValue) throws {
        guard !closed else { throw JSONRPCError.closed }
        try write(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
    }

    // MARK: - Internals

    private func write(_ object: [String: JSONValue]) throws {
        let data = try JSONEncoder().encode(JSONValue.object(object))
        // JSONEncoder escapes control characters, so the output is a single line.
        let line = String(decoding: data, as: UTF8.self)
        if traceTraffic { log(Self.traced("->", line)) }
        try transport.send(line: line)
    }

    private func handle(line: String) {
        if traceTraffic { log(Self.traced("<-", line)) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              case .object = value, value["jsonrpc"] != nil || value["id"] != nil || value["method"] != nil
        else {
            log("acp: non-JSON line: \(Self.loggable(line))")
            return
        }
        if let method = value["method"]?.stringValue {
            let params = value["params"] ?? .null
            if let id = value["id"], id != .null {
                dispatchRequest(id: id, method: method, params: params)
            } else {
                notificationHandler?(method, params)
            }
        } else if case let .number(n)? = value["id"], let id = Int(exactly: n),
                  let cont = pending.removeValue(forKey: id) {
            if let err = value["error"] {
                var code = -32603
                if case let .number(c)? = err["code"], let exact = Int(exactly: c) { code = exact }
                cont.resume(throwing: JSONRPCError(
                    code: code,
                    message: err["message"]?.stringValue ?? "Unknown error"))
            } else {
                cont.resume(returning: value["result"] ?? .null)
            }
        } else {
            log("acp: unmatched message: \(Self.loggable(line))")
        }
    }

    private func dispatchRequest(id: JSONValue, method: String, params: JSONValue) {
        let handler = requestHandler
        Task { [weak self] in
            var reply: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
            do {
                guard let handler else { throw JSONRPCError.methodNotFound }
                reply["result"] = try await handler(method, params)
            } catch let e as JSONRPCError {
                reply["error"] = .object(["code": .number(Double(e.code)), "message": .string(e.message)])
            } catch {
                reply["error"] = .object(["code": .number(-32603), "message": .string("\(error)")])
            }
            await self?.sendReply(reply)
        }
    }

    private func sendReply(_ reply: [String: JSONValue]) {
        guard !closed else { return }
        do { try write(reply) } catch { log("acp: reply failed: \(error)") }
    }

    private func didClose() {
        guard !closed else { return }
        closed = true
        let waiting = pending
        pending = [:]
        for (_, cont) in waiting { cont.resume(throwing: JSONRPCError.closed) }
        closeHandler?()
    }
}
