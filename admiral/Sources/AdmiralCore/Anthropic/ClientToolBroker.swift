import Foundation

/// Parks MCP `tools/call`s until the Messages client posts the matching `tool_result`s.
///
/// The wait lives here, on whatever thread called `wait` — never on the main actor and
/// never inside `MCPServer.handle` or `BridgeSocketServer`. Those both serve a call by
/// holding a connection slot until the handler returns; a park lasts up to the turn
/// cap, and the endpoint that would fulfill it is itself on the main actor.
public final class ClientToolBroker: @unchecked Sendable {
    private struct Park {
        var id: UUID
        var token: String
        var name: String
        var canonical: String
        var toolUseID: String?
        var order: Int
    }

    public enum Correlation: Equatable, Sendable {
        case waiting
        case ready([TurnCapture.ToolUse])
    }

    private let lock = NSLock()
    private var parks: [UUID: Park] = [:]
    private var order: [UUID] = []
    private var nextOrder = 0
    private var waiters: [UUID: CheckedContinuation<ClientToolResult, Never>] = [:]
    private var early: [UUID: ClientToolResult] = [:]

    public init() {}

    /// Record a park and return at once. The MCP side then `wait`s; the HTTP side can
    /// see the park before that wait is even stored.
    @discardableResult
    public func register(token: String, name: String, arguments: JSONValue) -> UUID {
        let id = UUID()
        let input = arguments == .null ? JSONValue.object([:]) : arguments
        lock.lock()
        nextOrder += 1
        parks[id] = Park(id: id, token: token, name: ClientToolNames.normalize(name),
                         canonical: CanonicalJSON.string(input), toolUseID: nil, order: nextOrder)
        order.append(id)
        lock.unlock()
        return id
    }

    public func wait(_ id: UUID) async -> ClientToolResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ClientToolResult, Never>) in
            lock.lock()
            if let result = early.removeValue(forKey: id) {
                lock.unlock()
                cont.resume(returning: result)
                return
            }
            guard parks[id] != nil else {
                lock.unlock()
                cont.resume(returning: .text("client tool call is no longer parked", isError: true))
                return
            }
            waiters[id] = cont
            lock.unlock()
        }
    }

    /// Register and wait. The socket server uses `register` + `wait` so the read loop
    /// can accept the next park before this one resolves; tests use that split too.
    public func park(token: String, name: String, arguments: JSONValue) async -> ClientToolResult {
        let id = register(token: token, name: name, arguments: arguments)
        return await wait(id)
    }

    public func outstanding(token: String) -> [ClientToolParkView] {
        lock.lock(); defer { lock.unlock() }
        return ordered(token).map { ClientToolParkView(name: $0.name, toolUseID: $0.toolUseID) }
    }

    public func hasOutstanding(token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return parks.values.contains { $0.token == token }
    }

    /// Match transcript `tool_use` blocks onto parks by normalized name + canonical
    /// input, oldest park first. Duplicate calls of the same tool line up in order.
    /// Ids are written onto the parks only when every block has a park, so a partial
    /// parallel set does not stick.
    public func correlate(token: String, uses: [TurnCapture.ToolUse]) -> Correlation {
        lock.lock(); defer { lock.unlock() }
        var used = Set<UUID>()
        var planned: [(UUID, TurnCapture.ToolUse)] = []
        var seenIDs = Set<String>()
        for use in uses {
            guard seenIDs.insert(use.id).inserted else { continue }
            if let existing = ordered(token).first(where: { $0.toolUseID == use.id }) {
                used.insert(existing.id)
                planned.append((existing.id, normalized(use)))
                continue
            }
            let name = ClientToolNames.normalize(use.name)
            let canonical = CanonicalJSON.string(use.input)
            guard let park = ordered(token).first(where: {
                $0.toolUseID == nil && !used.contains($0.id) && $0.name == name && $0.canonical == canonical
            }) else { return .waiting }
            used.insert(park.id)
            planned.append((park.id, normalized(use)))
        }
        guard !planned.isEmpty || uses.isEmpty else { return .waiting }
        if planned.isEmpty { return .waiting }
        for (id, use) in planned {
            guard var park = parks[id], park.toolUseID == nil else { continue }
            park.toolUseID = use.id
            parks[id] = park
        }
        return .ready(planned.map(\.1))
    }

    /// Fulfill every outstanding park in the set, or none of them.
    @discardableResult
    public func fulfillAll(token: String, blocks: [ClientToolResultBlock]) -> Bool {
        lock.lock()
        var completions: [(CheckedContinuation<ClientToolResult, Never>, ClientToolResult)] = []
        var earlyWrites: [(UUID, ClientToolResult)] = []
        var remove: [UUID] = []
        var seen = Set<UUID>()
        for block in blocks {
            guard let park = parks.values.first(where: { $0.token == token && $0.toolUseID == block.toolUseID }),
                  seen.insert(park.id).inserted else {
                lock.unlock()
                return false
            }
            remove.append(park.id)
            if let waiter = waiters[park.id] {
                completions.append((waiter, block.result))
            } else {
                earlyWrites.append((park.id, block.result))
            }
        }
        for id in remove {
            parks[id] = nil
            waiters[id] = nil
            order.removeAll { $0 == id }
        }
        for (id, result) in earlyWrites { early[id] = result }
        lock.unlock()
        for (waiter, result) in completions { waiter.resume(returning: result) }
        return true
    }

    /// Resume every still-waiting park for this token that has no transcript id yet
    /// (the HTTP turn gave up before Claude's calls were all visible). Parks already
    /// reported to the client stay parked.
    public func failUncorrelated(token: String, message: String) {
        complete(token: token, where: { $0.toolUseID == nil }, message: message)
    }

    /// Resume every park for this token. A deleted session, or an MCP process that
    /// went away, must not leave `wait` suspended.
    public func failAll(token: String, message: String) {
        complete(token: token, where: { _ in true }, message: message)
    }

    public func failIfWaiting(_ id: UUID, message: String) {
        _ = complete(id: id, result: .text(message, isError: true))
    }

    private func complete(token: String, where include: (Park) -> Bool, message: String) {
        lock.lock()
        let ids = ordered(token).filter(include).map(\.id)
        lock.unlock()
        for id in ids { failIfWaiting(id, message: message) }
    }

    @discardableResult
    private func complete(id: UUID, result: ClientToolResult) -> Bool {
        lock.lock()
        guard parks[id] != nil else { lock.unlock(); return false }
        parks[id] = nil
        order.removeAll { $0 == id }
        let waiter = waiters.removeValue(forKey: id)
        if waiter == nil { early[id] = result }
        lock.unlock()
        waiter?.resume(returning: result)
        return true
    }

    private func ordered(_ token: String) -> [Park] {
        order.compactMap { parks[$0] }.filter { $0.token == token }
    }

    private func normalized(_ use: TurnCapture.ToolUse) -> TurnCapture.ToolUse {
        TurnCapture.ToolUse(id: use.id, name: ClientToolNames.normalize(use.name), input: use.input)
    }
}
