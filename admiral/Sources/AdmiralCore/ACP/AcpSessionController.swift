import Foundation

/// Admiral's hook features at their ACP moments (UserPromptSubmit / Stop / PostToolUse /
/// SessionStart compact). Defined here; Task 7's `AcpHookAdapter` conforms.
public protocol AcpTurnHooks: Sendable {
    /// Every outgoing prompt passes through here; the return value is what is sent.
    func beforePrompt(_ text: String) async -> String
    /// Called on `end_turn` with the turn's accumulated reply; non-nil is sent as the next prompt.
    func afterTurn(lastAssistantMessage: String) async -> String?
    func onToolCall(_ update: AcpUpdate) async
    func onCompaction() async
}

/// Drives one ACP tab: the handshake, the turn, the client-side queue / steering, and the
/// agent's held requests (permission, elicitation). The second `SessionDriver`, beside the PTY.
///
/// Everything the connection hands over — notifications, agent→client requests, close, and
/// the results of the prompts and steers this controller sent — goes through ONE ordered
/// inbox consumed on the main actor. That is what keeps a turn's last `session/update` chunks
/// ahead of the `session/prompt` result that ends it (the actor delivers both in line order).
///
/// Turn state: `idle` → `prompting` (the hook ran or `session/prompt` is in flight) →
/// `settling` (the result is in; `afterTurn` is deciding the follow-up) → `prompting` again
/// (follow-up, then the queue) or `idle`. Status is `.busy` for `prompting` and `settling`,
/// `.idle` for `idle`, and `.shell` once the transport closed. `SessionStatus` has no
/// "waiting" case, so an open permission/elicitation keeps the tab `.busy` (it only arrives
/// inside a prompt) and is surfaced through `permissionRequested` / `question` instead.
@MainActor
public final class AcpSessionController: SessionDriver {
    public enum Phase: Equatable { case connecting, ready, failed(String), ended }

    /// Closures into `SessionManager`. All are called on the main actor.
    public struct Events {
        var status: (SessionStatus) -> Void
        var phase: (Phase) -> Void
        var sessionStarted: (
            _ acpSessionID: String, _ capabilities: AcpCapabilities, _ configOptions: [AcpConfigOption]
        ) -> Void
        var turnEnded: (AcpStopReason) -> Void
        var permissionRequested: (_ title: String) -> Void
        var question: ([AskQuestion]) -> Void
        var update: (AcpUpdate) -> Void

        public init(
            status: @escaping (SessionStatus) -> Void = { _ in },
            phase: @escaping (Phase) -> Void = { _ in },
            sessionStarted: @escaping (String, AcpCapabilities, [AcpConfigOption]) -> Void = { _, _, _ in },
            turnEnded: @escaping (AcpStopReason) -> Void = { _ in },
            permissionRequested: @escaping (String) -> Void = { _ in },
            question: @escaping ([AskQuestion]) -> Void = { _ in },
            update: @escaping (AcpUpdate) -> Void = { _ in }
        ) {
            self.status = status
            self.phase = phase
            self.sessionStarted = sessionStarted
            self.turnEnded = turnEnded
            self.permissionRequested = permissionRequested
            self.question = question
            self.update = update
        }
    }

    public enum Start: Equatable {
        case new
        case restore(acpSessionID: String)
        case fork(acpSessionID: String)
    }

    /// What the tab shows as waiting to go out, oldest first.
    public var queued: [String] { queue.map(\.text) }
    public private(set) var phase: Phase = .connecting
    public private(set) var acpSessionID: String?
    public private(set) var capabilities: AcpCapabilities?
    /// The agent process's pid, when the launcher knows it.
    public var pid: Int32?

    private let config: AcpAgentConfig
    private let connection: JSONRPCConnection
    private let mirror: TranscriptMirror
    private let mcpServers: [AcpMCPServer]
    private let hooks: AcpTurnHooks?
    private let events: Events

    private enum Turn { case idle, prompting, settling }
    /// A queued prompt; `hooked` = already through `beforePrompt` (a steer the agent bounced).
    private struct Outgoing { var text: String; var hooked: Bool }
    private enum Inbound: Sendable {
        case notification(String, JSONValue)
        case request(String, JSONValue, CheckedContinuation<JSONValue, Error>)
        case promptFinished(Result<JSONValue, Error>)
        case steerFinished(text: String, Result<JSONValue, Error>)
        case closed
    }

    private var turn: Turn = .idle
    private var queue: [Outgoing] = []
    private var turnReply = ""
    private var heldPermissions: [(options: [JSONValue], reply: CheckedContinuation<JSONValue, Error>)] = []
    private var heldElicitations: [(form: AcpElicitationForm, reply: CheckedContinuation<JSONValue, Error>)] = []
    private var lastStatus: SessionStatus?

    private let inbox: AsyncStream<Inbound>
    private let inboxIn: AsyncStream<Inbound>.Continuation
    private var pump: Task<Void, Never>?

    public init(
        config: AcpAgentConfig,
        connection: JSONRPCConnection,
        mirror: TranscriptMirror,
        mcpServer: AcpMCPServer?,
        hooks: AcpTurnHooks?,
        events: Events
    ) {
        self.config = config
        self.connection = connection
        self.mirror = mirror
        self.mcpServers = mcpServer.map { [$0] } ?? []
        self.hooks = hooks
        self.events = events
        (inbox, inboxIn) = AsyncStream.makeStream(of: Inbound.self)
    }

    deinit {
        inboxIn.finish()
        pump?.cancel()
    }

    // MARK: - Handshake

    public func start(_ start: Start) async {
        guard pump == nil else { return }
        let inboxIn = inboxIn
        await connection.onNotification { method, params in inboxIn.yield(.notification(method, params)) }
        await connection.onRequest { method, params in
            try await withCheckedThrowingContinuation { cont in
                if case .terminated = inboxIn.yield(.request(method, params, cont)) {
                    cont.resume(throwing: JSONRPCError.closed)
                }
            }
        }
        await connection.onClose { inboxIn.yield(.closed) }
        let inbox = inbox
        pump = Task { [weak self] in
            for await event in inbox { self?.handle(event) }
        }
        await connection.start()

        do {
            try await handshake(start)
        } catch {
            fail(Self.message(error))
        }
    }

    private struct HandshakeFailure: Error { let message: String }

    private func handshake(_ start: Start) async throws {
        let caps = AcpCapabilities(initializeResult: try await connection.request(
            "initialize", params: AcpClient.initializeParams()))
        capabilities = caps

        let sessionID: String
        var result: JSONValue
        switch start {
        case .new:
            result = try await connection.request(
                "session/new", params: AcpClient.newSessionParams(cwd: config.cwd, mcpServers: mcpServers))
            guard let id = result["sessionId"]?.stringValue else {
                throw HandshakeFailure(message: "agent returned no sessionId")
            }
            sessionID = id
        case let .restore(id):
            let method: String
            if caps.resume {
                method = "session/resume"
            } else if caps.loadSession {
                method = "session/load"
            } else {
                throw HandshakeFailure(message: "agent cannot restore sessions")
            }
            // Set first: `session/load` replays history as updates for this id before it returns.
            acpSessionID = id
            result = try await connection.request(method, params: AcpClient.loadOrResumeParams(
                sessionID: id, cwd: config.cwd, mcpServers: mcpServers))
            sessionID = id
        case let .fork(source):
            guard caps.fork else { throw HandshakeFailure(message: "agent cannot fork sessions") }
            result = try await connection.request("session/fork", params: AcpClient.forkParams(
                sessionID: source, cwd: config.cwd, mcpServers: mcpServers))
            guard let id = result["sessionId"]?.stringValue else {
                throw HandshakeFailure(message: "agent returned no sessionId")
            }
            sessionID = id
        }
        acpSessionID = sessionID

        if let mode = config.defaultMode {
            do {
                _ = try await connection.request(
                    "session/set_mode", params: AcpClient.setModeParams(sessionID: sessionID, modeID: mode))
            } catch {
                throw HandshakeFailure(message: "agent refused mode \(mode): \(Self.message(error))")
            }
        }
        var options = AcpConfigOption.decodeAll(result)
        if start == .new {
            for (id, value) in config.defaultConfigOptions.sorted(by: { $0.key < $1.key }) {
                do {
                    result = try await connection.request(
                        "session/set_config_option",
                        params: AcpClient.setConfigOptionParams(sessionID: sessionID, configID: id, value: value))
                } catch {
                    throw HandshakeFailure(message: "agent refused \(id)=\(value): \(Self.message(error))")
                }
                if result["configOptions"] != nil { options = AcpConfigOption.decodeAll(result) }
            }
        }

        guard phase == .connecting else { return }
        setPhase(.ready)
        events.sessionStarted(sessionID, caps, options)
        if let next = queue.first {
            queue.removeFirst()
            send(next)
        } else {
            publishStatus()
        }
    }

    // MARK: - SessionDriver

    public func submit(prompt: TerminalPrompt) -> Bool { accept(prompt.text) }
    public func submitTyped(_ text: String) -> Bool { accept(text) }
    public func deliver(_ text: String) -> Bool { accept(text) }

    /// The one decision for every input funnel. Queued counts as accepted; false means the
    /// text went nowhere (failed or ended tab).
    private func accept(_ text: String) -> Bool {
        switch (phase, turn) {
        case (.failed, _), (.ended, _):
            return false
        case (.ready, .idle):
            send(Outgoing(text: text, hooked: false))
        case (.ready, .prompting) where capabilities?.steering == true:
            steer(text)
        default:
            queue.append(Outgoing(text: text, hooked: false))
        }
        return true
    }

    /// `session/cancel`; the queue stays, and open requests are answered `cancelled`.
    public func interrupt() {
        releaseHeldRequests()
        guard let sid = acpSessionID, phase == .ready else { return }
        let connection = connection
        Task { try? await connection.notify("session/cancel", params: AcpClient.sessionParams(sessionID: sid)) }
    }

    /// The chat card's answers become the oldest open elicitation's `accept` content.
    public func answer(questions: [AskQuestion], answers: [String]) -> Bool {
        guard !heldElicitations.isEmpty else { return false }
        let held = heldElicitations.removeFirst()
        held.reply.resume(returning: .object([
            "action": .string("accept"), "content": held.form.content(answers: answers),
        ]))
        return true
    }

    /// Allows the oldest open permission request: `allow_once` if offered, else the first `allow_*`.
    public func allowPermission() -> Bool {
        guard let held = heldPermissions.first else { return false }
        let kinds = held.options.compactMap { o in o["kind"]?.stringValue.map { (kind: $0, option: o) } }
        let pick = kinds.first { $0.kind == "allow_once" } ?? kinds.first { $0.kind.hasPrefix("allow_") }
        guard let id = pick?.option["optionId"]?.stringValue else { return false }
        heldPermissions.removeFirst()
        held.reply.resume(returning: .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string(id)]),
        ]))
        return true
    }

    public func readScreen() -> String? { nil }
    public func sendKeys(_ text: String) -> Bool { false }

    /// `session/close` when advertised (bounded, so a dead agent cannot stall it), then the transport.
    public func terminate() {
        let connection = connection
        let close = capabilities?.close == true && phase == .ready ? acpSessionID : nil
        Task {
            if let sid = close {
                await Self.bounded(seconds: 2) {
                    _ = try? await connection.request("session/close", params: AcpClient.sessionParams(sessionID: sid))
                }
            }
            await connection.close()
        }
    }

    // MARK: - Sending

    private func send(_ item: Outgoing) {
        turn = .prompting
        turnReply = ""
        publishStatus()
        let (connection, hooks, inboxIn) = (connection, hooks, inboxIn)
        Task { [weak self] in
            var text = item.text
            if !item.hooked, let hooks { text = await hooks.beforePrompt(text) }
            guard let self, self.phase == .ready, let sid = self.acpSessionID else { return }
            self.mirror.userPrompt(text)
            let result: Result<JSONValue, Error>
            do {
                result = .success(try await connection.request(
                    "session/prompt", params: AcpClient.promptParams(sessionID: sid, text: text)))
            } catch {
                result = .failure(error)
            }
            inboxIn.yield(.promptFinished(result))
        }
    }

    /// Mid-turn delivery on `_session/steering`. Mirrored only once the agent took it; a
    /// `promptRequired` answer (or an error) queues it as an already-hooked prompt.
    private func steer(_ raw: String) {
        let (connection, hooks, inboxIn) = (connection, hooks, inboxIn)
        guard let sid = acpSessionID else { return }
        Task {
            var text = raw
            if let hooks { text = await hooks.beforePrompt(text) }
            let result: Result<JSONValue, Error>
            do {
                result = .success(try await connection.request(
                    "_session/steering", params: AcpClient.steeringParams(sessionID: sid, text: text)))
            } catch {
                result = .failure(error)
            }
            inboxIn.yield(.steerFinished(text: text, result))
        }
    }

    // MARK: - Inbox

    private func handle(_ event: Inbound) {
        switch event {
        case let .notification(method, params): notification(method, params)
        case let .request(method, params, reply): request(method, params, reply)
        case let .promptFinished(result): promptFinished(result)
        case let .steerFinished(text, result): steerFinished(text, result)
        case .closed: closed()
        }
    }

    private func notification(_ method: String, _ params: JSONValue) {
        guard method == "session/update", let decoded = AcpUpdate.decode(params),
              decoded.sessionID == acpSessionID else { return }
        let update = decoded.update
        mirror.apply(update)
        if case let .agentMessage(text) = update, turn == .prompting { turnReply += text }
        events.update(update)
        guard let hooks else { return }
        switch update {
        case .toolCall, .toolCallUpdate: Task { await hooks.onToolCall(update) }
        case .compaction: Task { await hooks.onCompaction() }
        default: break
        }
    }

    private func request(_ method: String, _ params: JSONValue, _ reply: CheckedContinuation<JSONValue, Error>) {
        guard phase != .ended else { return reply.resume(returning: Self.cancelledReply(method)) }
        switch method {
        case "session/request_permission":
            heldPermissions.append((params["options"]?.arrayValue ?? [], reply))
            events.permissionRequested(params["toolCall"]?["title"]?.stringValue ?? "Permission requested")
        case "elicitation/create":
            guard let form = AcpElicitationForm(params: params) else {
                return reply.resume(returning: .object(["action": .string("decline")]))
            }
            heldElicitations.append((form, reply))
            events.question(form.questions)
        default:
            reply.resume(throwing: JSONRPCError.methodNotFound)
        }
    }

    private func promptFinished(_ result: Result<JSONValue, Error>) {
        mirror.endTurn()
        guard turn == .prompting, phase == .ready else { return }
        let reply = turnReply
        turnReply = ""
        turn = .settling
        guard case let .success(value) = result else { return settle(followUp: nil, drain: true) }
        let reason = value["stopReason"]?.stringValue.flatMap(AcpStopReason.init(rawValue:)) ?? .endTurn
        events.turnEnded(reason)
        guard reason == .endTurn, let hooks else { return settle(followUp: nil, drain: reason != .cancelled) }
        Task { [weak self] in
            let followUp = await hooks.afterTurn(lastAssistantMessage: reply)
            self?.settle(followUp: followUp, drain: true)
        }
    }

    /// After a turn: the hook's follow-up first, then the queue (unless interrupted), else idle.
    private func settle(followUp: String?, drain: Bool) {
        guard turn == .settling, phase == .ready else { return }
        if let followUp {
            send(Outgoing(text: followUp, hooked: false))
        } else if drain, !queue.isEmpty {
            send(queue.removeFirst())
        } else {
            turn = .idle
            publishStatus()
        }
    }

    private func steerFinished(_ text: String, _ result: Result<JSONValue, Error>) {
        guard phase == .ready else { return }
        if case let .success(value) = result, !Self.promptRequired(value) {
            mirror.userPrompt(text)
            return
        }
        let item = Outgoing(text: text, hooked: true)
        if turn == .idle { send(item) } else { queue.append(item) }
    }

    private func closed() {
        mirror.endTurn()
        releaseHeldRequests()
        turn = .idle
        turnReply = ""
        setPhase(.ended)
        publishStatus()
    }

    // MARK: - Helpers

    private func releaseHeldRequests() {
        let (permissions, elicitations) = (heldPermissions, heldElicitations)
        heldPermissions = []
        heldElicitations = []
        for held in permissions { held.reply.resume(returning: Self.cancelledReply("session/request_permission")) }
        for held in elicitations { held.reply.resume(returning: Self.cancelledReply("elicitation/create")) }
    }

    private static func cancelledReply(_ method: String) -> JSONValue {
        method == "elicitation/create"
            ? .object(["action": .string("cancel")])
            : .object(["outcome": .object(["outcome": .string("cancelled")])])
    }

    private func fail(_ message: String) {
        guard phase == .connecting else { return }
        setPhase(.failed(message))
    }

    private func setPhase(_ new: Phase) {
        guard phase != new else { return }
        phase = new
        events.phase(new)
    }

    private func publishStatus() {
        let status: SessionStatus = phase == .ended ? .shell : (turn == .idle ? .idle : .busy)
        guard status != lastStatus else { return }
        lastStatus = status
        events.status(status)
    }

    /// The steering result's shape is agent-specific; any `promptRequired` marker means "not taken".
    static func promptRequired(_ result: JSONValue) -> Bool {
        let marker = "promptRequired"
        if result.stringValue == marker { return true }
        return ["outcome", "status", "result", "stopReason"].contains { result[$0]?.stringValue == marker }
    }

    private static func message(_ error: Error) -> String {
        switch error {
        case let e as HandshakeFailure: e.message
        case let e as JSONRPCError: e.message
        default: "\(error)"
        }
    }

    private static func bounded(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await work() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }
}

/// An `elicitation/create` form mapped onto the AskUserQuestion card, and the card's answers
/// mapped back into the form's `content`.
///
/// Fields: the schema's `required` keys in their listed order, then the rest by name (a JSON
/// object has no order). Each field is one question: header = `title` ?? key, question =
/// `description` ?? `title` ?? the form's `message`.
/// - `oneOf`/`anyOf` `{const,title}` → options labelled by title, answered with the const.
/// - `enum` (+ optional `enumNames`) → options, answered with the enum value.
/// - `array` → multi-select over `items`' choices; the card joins picks with ", ", split back.
/// - `boolean` → Yes / No → true / false.
/// - `number` / `integer` → free text parsed as a number (kept as text if it is not one).
/// - anything else → free text.
/// An unanswered field is left out of `content`.
struct AcpElicitationForm {
    struct Field {
        enum Kind { case text, number, boolean, choice, multi }
        var key: String
        var kind: Kind
        /// label → value sent back.
        var choices: [(label: String, value: String)]
    }

    let fields: [Field]
    let questions: [AskQuestion]

    /// nil when this is not a form request (e.g. `mode: "url"`) or has no fields.
    init?(params: JSONValue) {
        if let mode = params["mode"]?.stringValue, mode != "form" { return nil }
        guard case let .object(props)? = params["requestedSchema"]?["properties"], !props.isEmpty else { return nil }
        let required = (params["requestedSchema"]?["required"]?.arrayValue ?? []).compactMap(\.stringValue)
        let keys = required.filter { props[$0] != nil } + props.keys.filter { !required.contains($0) }.sorted()
        let message = params["message"]?.stringValue ?? ""
        var fields: [Field] = []
        var questions: [AskQuestion] = []
        for key in keys {
            guard let schema = props[key] else { continue }
            let field = Self.field(key: key, schema: schema)
            fields.append(field)
            let title = schema["title"]?.stringValue
            questions.append(AskQuestion(
                question: schema["description"]?.stringValue ?? title ?? message,
                header: title ?? key,
                multiSelect: field.kind == .multi,
                options: field.choices.map { AskOption(label: $0.label) }))
        }
        self.fields = fields
        self.questions = questions
    }

    private static func field(key: String, schema: JSONValue) -> Field {
        switch schema["type"]?.stringValue {
        case "boolean":
            return Field(key: key, kind: .boolean, choices: [("Yes", "true"), ("No", "false")])
        case "number", "integer":
            return Field(key: key, kind: .number, choices: [])
        case "array":
            return Field(key: key, kind: .multi, choices: choices(schema["items"] ?? .null))
        default:
            let c = choices(schema)
            return Field(key: key, kind: c.isEmpty ? .text : .choice, choices: c)
        }
    }

    private static func choices(_ schema: JSONValue) -> [(label: String, value: String)] {
        if let list = (schema["oneOf"] ?? schema["anyOf"])?.arrayValue {
            return list.compactMap { o in
                guard let value = o["const"]?.stringValue else { return nil }
                return (o["title"]?.stringValue ?? value, value)
            }
        }
        let values = (schema["enum"]?.arrayValue ?? []).compactMap(\.stringValue)
        let names = (schema["enumNames"]?.arrayValue ?? []).compactMap(\.stringValue)
        return values.enumerated().map { i, v in (i < names.count ? names[i] : v, v) }
    }

    func content(answers: [String]) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for (i, field) in fields.enumerated() where i < answers.count {
            let answer = answers[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { continue }
            func value(_ label: String) -> String { field.choices.first { $0.label == label }?.value ?? label }
            switch field.kind {
            case .text: out[field.key] = .string(answer)
            case .choice: out[field.key] = .string(value(answer))
            case .number: out[field.key] = Double(answer).map(JSONValue.number) ?? .string(answer)
            case .boolean:
                let v = value(answer).lowercased()
                out[field.key] = ["true", "yes"].contains(v) ? .bool(true)
                    : ["false", "no"].contains(v) ? .bool(false) : .string(answer)
            case .multi:
                out[field.key] = .array(answer.components(separatedBy: ", ").map { .string(value($0)) })
            }
        }
        return .object(out)
    }
}
