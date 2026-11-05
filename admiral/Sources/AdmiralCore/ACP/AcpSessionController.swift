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
/// the results of the prompts and steers this controller sent — goes through ONE inbox
/// consumed on the main actor. Notifications and close are yielded in line order from the
/// connection's read loop, which is what keeps a turn's last `session/update` chunks ahead of
/// the `session/prompt` result that ends it. Agent→client requests are NOT in line: the
/// connection hands each to its own Task (`dispatchRequest`), so a permission request or an
/// elicitation can reach the inbox after updates the agent sent later. Nothing here depends on
/// their order relative to updates — they are held until answered, one card at a time.
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
        /// The tab went idle after an `end_turn` with nothing sent next (no follow-up, queue empty
        /// or held): the agent is now waiting on the user. Never fires between a turn and the
        /// follow-up or queued prompt that continues it.
        var settledIdle: () -> Void
        /// A Stop block's follow-up is about to go out as the next prompt — Admiral's, not the user's.
        var followUpSent: (String) -> Void
        /// The agent's oldest open permission request / elicitation, one at a time: the next
        /// is surfaced only once the one before it is answered (after `requestResolved`).
        var permissionRequested: (_ title: String) -> Void
        var question: ([AskQuestion]) -> Void
        /// Open requests were answered or released (cancelled) — any card showing them is done.
        /// Always reported before the next open request is surfaced.
        var requestResolved: () -> Void
        /// `queued` changed.
        var queueChanged: ([String]) -> Void
        var update: (AcpUpdate) -> Void
        /// The agent's config options changed: fired right after `sessionStarted`, after every
        /// `setConfigOption`, and on `config_option_update` / `current_mode_update`.
        var configOptionsChanged: ([AcpConfigOption]) -> Void
        /// Admiral's own note for the tab's ACP log (an `acp:` line).
        var log: (String) -> Void

        public init(
            status: @escaping (SessionStatus) -> Void = { _ in },
            phase: @escaping (Phase) -> Void = { _ in },
            sessionStarted: @escaping (String, AcpCapabilities, [AcpConfigOption]) -> Void = { _, _, _ in },
            turnEnded: @escaping (AcpStopReason) -> Void = { _ in },
            settledIdle: @escaping () -> Void = {},
            followUpSent: @escaping (String) -> Void = { _ in },
            permissionRequested: @escaping (String) -> Void = { _ in },
            question: @escaping ([AskQuestion]) -> Void = { _ in },
            requestResolved: @escaping () -> Void = {},
            queueChanged: @escaping ([String]) -> Void = { _ in },
            update: @escaping (AcpUpdate) -> Void = { _ in },
            configOptionsChanged: @escaping ([AcpConfigOption]) -> Void = { _ in },
            log: @escaping (String) -> Void = { _ in }
        ) {
            self.status = status
            self.phase = phase
            self.sessionStarted = sessionStarted
            self.turnEnded = turnEnded
            self.settledIdle = settledIdle
            self.followUpSent = followUpSent
            self.permissionRequested = permissionRequested
            self.question = question
            self.requestResolved = requestResolved
            self.queueChanged = queueChanged
            self.update = update
            self.configOptionsChanged = configOptionsChanged
            self.log = log
        }
    }

    public enum Start: Equatable {
        case new
        case restore(acpSessionID: String)
        case fork(acpSessionID: String)
    }

    /// What the tab shows as waiting to go out, oldest first.
    public var queued: [String] { queue.map(\.raw) }
    public private(set) var phase: Phase = .connecting
    public private(set) var acpSessionID: String?
    public private(set) var capabilities: AcpCapabilities?
    /// What the agent offers now (mode, model, effort, …), as it last said.
    public private(set) var configOptions: [AcpConfigOption] = []
    /// The agent process's pid, when the launcher knows it.
    public var pid: Int32?
    /// `accept` queues: whatever it took goes out once the agent can take it.
    public let acceptanceIsDelivery = true

    private let config: AcpAgentConfig
    private let connection: JSONRPCConnection
    private let mirror: TranscriptMirror
    private let mcpServers: [AcpMCPServer]
    /// Admiral offered this tab its session bridge (the listener was running at launch).
    public var offersBridge: Bool { !mcpServers.isEmpty }
    private let hooks: AcpTurnHooks?
    private let events: Events

    private enum Turn { case idle, prompting, settling }
    /// A queued prompt. `raw` is what the user (or Admiral) wrote — what the mirror shows, as a
    /// claude transcript never shows a hook's `additionalContext` as part of the prompt; `text`
    /// is what goes on the wire, and `hooked` = it already went through `beforePrompt` (a steer
    /// the agent bounced, or a prompt put back by an interrupt).
    private struct Outgoing {
        var raw: String
        var text: String
        var hooked: Bool
        init(text: String) { (raw, self.text, hooked) = (text, text, false) }
        init(raw: String, hookedText: String) { (self.raw, text, hooked) = (raw, hookedText, true) }

        /// Through `beforePrompt` once; an already-hooked item passes as it is.
        func hooked(by hooks: AcpTurnHooks?) async -> Outgoing {
            guard !hooked, let hooks else { return self }
            return Outgoing(raw: raw, hookedText: await hooks.beforePrompt(text))
        }
    }
    private enum Inbound: Sendable {
        case notification(String, JSONValue)
        case request(String, JSONValue, CheckedContinuation<JSONValue, Error>)
        case promptFinished(Result<JSONValue, Error>)
        case steerFinished(Outgoing, Result<JSONValue, Error>)
        /// `session/load` answered: every replayed update is already ahead of this in the inbox.
        case replayDone
        case closed
    }

    private var turn: Turn = .idle
    private var queue: [Outgoing] = [] {
        didSet { events.queueChanged(queued) }
    }
    private var turnReply = ""
    private var heldPermissions: [
        (title: String, options: [JSONValue], reply: CheckedContinuation<JSONValue, Error>)
    ] = []
    private var heldElicitations: [(form: AcpElicitationForm, reply: CheckedContinuation<JSONValue, Error>)] = []
    private var lastStatus: SessionStatus?
    /// True once this turn's `session/prompt` is on the wire: steering before that would land
    /// ahead of the prompt it is meant to follow.
    private var promptSent = false
    /// One steer at a time, so steers reach the agent in arrival order.
    private var steerInFlight = false
    /// The agent bounced a steer this turn (it is idle or refused): stop steering until the next turn.
    private var steerBounced = false
    /// Set by an interrupt (or a `cancelled` stop): the queue is held, nothing new goes out on
    /// its own — no follow-up, no drain, and a prompt still in its hook is put back. The next
    /// input clears it and starts draining from the oldest item.
    private var queueHeld = false
    /// The last finished turn's stop reason, nil after a failed prompt; read once the tab settles idle.
    private var lastStopReason: AcpStopReason?
    /// A turn that ended while a steer was in flight settles once the steer's answer is in,
    /// so a bounced steer goes back ahead of anything newer.
    private var pendingSettle: String??
    /// See `init(replayIntoMirror:)`.
    private let replayIntoMirror: Bool
    /// Between sending `session/load` and its `.replayDone`: the updates are history.
    private var replaying = false
    /// Bumped by every agent push of the options (`config_option_update` / `current_mode_update`),
    /// so a `set_config_option` answer that raced a newer push does not put the older list back.
    private var optionPushes = 0

    private let inbox: AsyncStream<Inbound>
    private let inboxIn: AsyncStream<Inbound>.Continuation
    private var pump: Task<Void, Never>?

    public init(
        config: AcpAgentConfig,
        connection: JSONRPCConnection,
        mirror: TranscriptMirror,
        mcpServer: AcpMCPServer?,
        hooks: AcpTurnHooks?,
        events: Events,
        replayIntoMirror: Bool = true
    ) {
        self.replayIntoMirror = replayIntoMirror
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
        } catch let error as JSONRPCError where error == .closed {
            fail(Self.exitedBeforeStart)
        } catch {
            fail(Self.message(error))
        }
    }

    private struct HandshakeFailure: Error { let message: String }

    private func handshake(_ start: Start) async throws {
        let caps = AcpCapabilities(initializeResult: try await connection.request(
            "initialize", params: AcpClient.initializeParams()))
        capabilities = caps
        // The bridge is an HTTP MCP server: an agent that did not advertise HTTP is not sent it.
        let mcpServers = caps.mcpHTTP ? self.mcpServers : []

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
            replaying = method == "session/load"
            result = try await connection.request(method, params: AcpClient.loadOrResumeParams(
                sessionID: id, cwd: config.cwd, mcpServers: mcpServers))
            if replaying { inboxIn.yield(.replayDone) }
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

        configOptions = AcpConfigOption.decodeAll(result)
        // Only a new session: a restored or forked one keeps its own mode, which the agent restores.
        if start == .new { try await applyStartingOptions(sessionID: sessionID) }

        guard phase == .connecting else { return }
        setPhase(.ready)
        events.sessionStarted(sessionID, caps, configOptions)
        events.configOptionsChanged(configOptions)
        advance()
        publishStatus()
    }

    /// The agent's starting options, in id order, each through the option's own setter. The
    /// catalog behind them may be stale (`bypassPermissions` is not offered to a root user), so
    /// an option or value the agent does not offer is skipped and logged; a value it refuses
    /// fails the handshake.
    private func applyStartingOptions(sessionID: String) async throws {
        for (id, value) in config.defaultConfigOptions.sorted(by: { $0.key < $1.key }) {
            guard let option = configOptions.first(where: { $0.id == id }) else {
                events.log("acp: starting option \(id) not offered by the agent \u{2014} skipped")
                continue
            }
            guard option.values.contains(where: { $0.value == value }) else {
                events.log("acp: starting option \(id)=\(value) not offered by the agent \u{2014} skipped")
                continue
            }
            do {
                try await set(option, to: value, sessionID: sessionID)
            } catch {
                throw HandshakeFailure(message: "agent refused \(id)=\(value): \(Self.message(error))")
            }
        }
    }

    /// One option to `value`, by its setter. `set_config_option` answers with the full list,
    /// which replaces ours; `set_mode` answers nothing, so the mode is updated here.
    private func set(_ option: AcpConfigOption, to value: String, sessionID: String) async throws {
        switch option.setter {
        case .configOption:
            let pushesBefore = optionPushes
            let result = try await connection.request(
                "session/set_config_option",
                params: AcpClient.setConfigOptionParams(sessionID: sessionID, configID: option.id, value: value))
            // A push that landed while this was in flight is newer than the answer's list: keep it,
            // and patch only the picked value.
            if result["configOptions"]?.arrayValue != nil, optionPushes == pushesBefore {
                configOptions = AcpConfigOption.decodeAll(result)
            } else {
                configOptions = configOptions.map { o in
                    guard o.id == option.id else { return o }
                    var changed = o
                    changed.currentValue = value
                    return changed
                }
            }
        case .legacyMode:
            _ = try await connection.request(
                "session/set_mode", params: AcpClient.setModeParams(sessionID: sessionID, modeID: value))
            configOptions = configOptions.applyingCurrentMode(value)
        }
    }

    /// The composer's picker: one option to `value`. Throws the agent's refusal as it came
    /// (`JSONRPCError`), or `NotSettable` when there is no session or no such option.
    public func setConfigOption(id: String, value: String) async throws {
        guard phase == .ready, let sid = acpSessionID else { throw NotSettable(message: "the agent is not running") }
        guard let option = configOptions.first(where: { $0.id == id }) else {
            throw NotSettable(message: "the agent does not offer it")
        }
        try await set(option, to: value, sessionID: sid)
        events.configOptionsChanged(configOptions)
    }

    struct NotSettable: Error { let message: String }

    // MARK: - SessionDriver

    public func submit(prompt: TerminalPrompt) -> Bool { accept(prompt.text) }
    public func submitTyped(_ text: String) -> Bool { accept(text) }
    public func deliver(_ text: String) -> Bool { accept(text) }

    /// The one decision for every input funnel. Queued counts as accepted; false means the
    /// text went nowhere (failed or ended tab).
    ///
    /// Every input joins the back of the queue and `advance` moves the queue, so nothing ever
    /// overtakes an older item — whether it goes out as a prompt or a steer.
    private func accept(_ text: String) -> Bool {
        switch phase {
        case .failed, .ended: return false
        case .connecting, .ready: break
        }
        queue.append(Outgoing(text: text))
        queueHeld = false
        advance()
        return true
    }

    /// Sends the queue head when the agent can take it: as a prompt when idle, as a steer
    /// mid-prompt (one at a time) when steering is advertised. Otherwise it waits for `settle`.
    private func advance() {
        guard phase == .ready, !queueHeld, !queue.isEmpty else { return }
        switch turn {
        case .idle:
            send(queue.removeFirst())
        case .prompting where promptSent && !steerInFlight && !steerBounced && capabilities?.steering == true:
            steer(queue.removeFirst())
        case .prompting, .settling:
            break
        }
    }

    /// `session/cancel`; the queue stays, and open requests are answered `cancelled`.
    public func interrupt() {
        queueHeld = true
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
        resolved()
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
        resolved()
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
        promptSent = false
        steerBounced = false
        publishStatus()
        let (connection, hooks, inboxIn) = (connection, hooks, inboxIn)
        Task { [weak self] in
            let item = await item.hooked(by: hooks)
            let text = item.text
            guard let self, self.phase == .ready, let sid = self.acpSessionID else { return }
            guard !self.queueHeld else {
                // Interrupted before it went out: not sent, and not lost — back at the head.
                self.queue.insert(item, at: 0)
                self.turn = .idle
                self.publishStatus()
                return
            }
            self.mirror.userPrompt(item.raw)
            self.promptSent = true
            self.advance()
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
    private func steer(_ item: Outgoing) {
        let (connection, hooks, inboxIn) = (connection, hooks, inboxIn)
        guard let sid = acpSessionID else { return }
        steerInFlight = true
        Task { [weak self] in
            let item = await item.hooked(by: hooks)
            if self?.queueHeld == true {
                self?.steerFinished(item, .success(.string("promptRequired")))
                return
            }
            let result: Result<JSONValue, Error>
            do {
                result = .success(try await connection.request(
                    "_session/steering", params: AcpClient.steeringParams(sessionID: sid, text: item.text)))
            } catch {
                result = .failure(error)
            }
            inboxIn.yield(.steerFinished(item, result))
        }
    }

    // MARK: - Inbox

    private func handle(_ event: Inbound) {
        switch event {
        case let .notification(method, params): notification(method, params)
        case let .request(method, params, reply): request(method, params, reply)
        case let .promptFinished(result): promptFinished(result)
        case let .steerFinished(item, result): steerFinished(item, result)
        case .replayDone:
            replaying = false
            // A replay written into a fresh mirror lands as its own lines, not ahead of the next prompt.
            if replayIntoMirror { mirror.endTurn() }
        case .closed: closed()
        }
    }

    private func notification(_ method: String, _ params: JSONValue) {
        guard method == "session/update", let decoded = AcpUpdate.decode(params),
              decoded.sessionID == acpSessionID else { return }
        let update = decoded.update
        // A `session/load` replay is history: the tab's mirror already holds it (same local id,
        // same file) unless it was lost, and its tool calls / compactions are not new events.
        if replaying {
            if replayIntoMirror { mirror.apply(update) }
            events.update(update)
            return
        }
        mirror.apply(update)
        if case let .agentMessage(text) = update, turn == .prompting { turnReply += text }
        switch update {
        case let .configOptions(options):
            optionPushes += 1
            configOptions = options
            events.configOptionsChanged(options)
        case let .currentMode(mode):
            optionPushes += 1
            configOptions = configOptions.applyingCurrentMode(mode)
            events.configOptionsChanged(configOptions)
        default: break
        }
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
            heldPermissions.append((Self.permissionTitle(params), params["options"]?.arrayValue ?? [], reply))
            if heldPermissions.count == 1 { events.permissionRequested(heldPermissions[0].title) }
        case "elicitation/create":
            guard let form = AcpElicitationForm(params: params) else {
                return reply.resume(returning: .object(["action": .string("decline")]))
            }
            heldElicitations.append((form, reply))
            if heldElicitations.count == 1 { events.question(form.questions) }
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
        lastStopReason = nil
        guard case let .success(value) = result else {
            // No `turnEnded`: the tab just goes idle. The error is written as the turn's reply so
            // the Chat shows it, and so a TabRun that missed the busy blip still sees output and ends.
            if case let .failure(error) = result {
                mirror.apply(.agentMessage("ACP error: \(Self.message(error))"))
                mirror.endTurn()
            }
            return settle(followUp: nil)
        }
        let reason = value["stopReason"]?.stringValue.flatMap(AcpStopReason.init(rawValue:)) ?? .endTurn
        lastStopReason = reason
        events.turnEnded(reason)
        if reason == .cancelled { queueHeld = true }
        guard reason == .endTurn, let hooks else { return settle(followUp: nil) }
        Task { [weak self] in
            let followUp = await hooks.afterTurn(lastAssistantMessage: reply)
            self?.settle(followUp: followUp)
        }
    }

    /// After a turn: the hook's follow-up first, then the queue, else idle. A held queue (an
    /// interrupt during the turn or while settling) drops the follow-up and sends nothing.
    private func settle(followUp: String?) {
        guard turn == .settling, phase == .ready else { return }
        guard !steerInFlight else { pendingSettle = .some(followUp); return }
        if let followUp, !queueHeld {
            // Already hooked: a Stop block's continuation is not a user prompt (claude fires no
            // UserPromptSubmit for it). Through `beforePrompt` it would reset the goal-review and
            // watchdog budgets the block just spent, and the turn would loop forever.
            events.followUpSent(followUp)
            send(Outgoing(raw: followUp, hookedText: followUp))
        } else {
            turn = .idle
            advance()
            if turn == .idle, lastStopReason == .endTurn { events.settledIdle() }
            publishStatus()
        }
    }

    private func steerFinished(_ item: Outgoing, _ result: Result<JSONValue, Error>) {
        steerInFlight = false
        guard phase == .ready else { return }
        if case let .success(value) = result, !Self.promptRequired(value) {
            mirror.userPrompt(item.raw)
        } else {
            // Bounced (or failed, or interrupted before it went out): back at the head, ahead of newer items.
            queue.insert(item, at: 0)
            steerBounced = true
        }
        if let followUp = pendingSettle {
            pendingSettle = nil
            settle(followUp: followUp)
        } else {
            advance()
        }
    }

    /// The handshake's reason when the transport closed under it. Both orders of the close event
    /// and the failed request land on this same reason, so the tab never reads "ended" for an
    /// agent that never started (a stopped container, a missing binary).
    static let exitedBeforeStart = "the agent exited before the session started"

    private func closed() {
        // Before the session started this is a failed launch, not an ended session.
        fail(Self.exitedBeforeStart)
        mirror.endTurn()
        releaseHeldRequests()
        turn = .idle
        steerInFlight = false
        pendingSettle = nil
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
        if !permissions.isEmpty || !elicitations.isEmpty { events.requestResolved() }
    }

    /// One open request was answered: say so, then surface what is still open — the next of
    /// each kind (a resolution closes every card, so a held request of the other kind is
    /// shown again rather than lost).
    private func resolved() {
        events.requestResolved()
        if let next = heldPermissions.first { events.permissionRequested(next.title) }
        if let next = heldElicitations.first { events.question(next.form.questions) }
    }

    private static func permissionTitle(_ params: JSONValue) -> String {
        params["toolCall"]?["title"]?.stringValue ?? "Permission requested"
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

    static func message(_ error: Error) -> String {
        switch error {
        case let e as HandshakeFailure: e.message
        case let e as NotSettable: e.message
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
