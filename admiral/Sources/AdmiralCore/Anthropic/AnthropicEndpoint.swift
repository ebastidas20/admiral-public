import Foundation

/// The Anthropic-compatible endpoint: routes `POST /v1/messages` to the Admiral tab
/// named by the required `ADMIRAL_TAB_NAME` header. No API token is required.
/// `model` is echoed on the response and never picks a tab. A new scratch tab also
/// receives it as `claude --model` when it names a `ScheduleModel` alias (`haiku`,
/// `claude-haiku`, …); the first request's alias is the process's model.
/// Owns the whole request lifecycle — tab resolution, delta detection, busy gate,
/// injection, transcript capture, completion — and emits raw HTTP bytes so the
/// socket layer stays a dumb pipe. One request in flight per tab.
@MainActor
public final class AnthropicEndpoint {
    public struct Config: Sendable {
        /// How long a request waits for a busy tab before 529.
        public var busyWaitTimeout: TimeInterval = 30
        /// If busy is never observed after injecting, complete once output exists
        /// and the tab reads idle after this long (fast turns can slip the 1s poll).
        public var busySeenTimeout: TimeInterval = 10
        /// Hard cap on a turn; return whatever was captured.
        public var turnTimeout: TimeInterval = 600
        public var pollInterval: TimeInterval = 1.0
        /// SSE keep-alive ping cadence while no text is flowing.
        public var pingInterval: TimeInterval = 15
        /// SO requests: if the tab reads idle while the tripwire is still armed with no
        /// Stop block recorded, the Stop hook isn't firing — fail fast instead of
        /// waiting out turnTimeout.
        public var structuredOutputGrace: TimeInterval = 15
        /// How long to wait for a freshly commissioned claude to write its session file
        /// (proof the process booted) before the first inject. A wait, not a gate — on
        /// timeout the inject attempts proceed anyway.
        public var injectReadyTimeout: TimeInterval = 30
        /// Per-attempt window for the transcript to gain the injected user message —
        /// the ground truth that the submit reached claude's TUI.
        public var injectVerifyTimeout: TimeInterval = 10
        /// Inject attempts before giving up and letting the turn timeouts govern.
        public var injectMaxAttempts: Int = 3
        public init(busyWaitTimeout: TimeInterval = 30, busySeenTimeout: TimeInterval = 10,
                    turnTimeout: TimeInterval = 600, pollInterval: TimeInterval = 1.0,
                    pingInterval: TimeInterval = 15, structuredOutputGrace: TimeInterval = 15,
                    injectReadyTimeout: TimeInterval = 30, injectVerifyTimeout: TimeInterval = 10,
                    injectMaxAttempts: Int = 3) {
            self.busyWaitTimeout = busyWaitTimeout
            self.busySeenTimeout = busySeenTimeout
            self.turnTimeout = turnTimeout
            self.pollInterval = pollInterval
            self.pingInterval = pingInterval
            self.structuredOutputGrace = structuredOutputGrace
            self.injectReadyTimeout = injectReadyTimeout
            self.injectVerifyTimeout = injectVerifyTimeout
            self.injectMaxAttempts = injectMaxAttempts
        }
    }

    /// The tab a request targets. `HTTPWire.parse` lowercases header keys, so the
    /// lookup key and the name clients type differ only in case.
    static let tabNameHeader = "admiral_tab_name"
    static let tabNameHeaderWireName = "ADMIRAL_TAB_NAME"
    static let sessionIDHeader = "admiral_session_id"
    static let sessionIDHeaderWireName = "ADMIRAL_SESSION_ID"
    static let cwdHeader = "admiral_cwd"
    static let cwdHeaderWireName = "ADMIRAL_CWD"

    private let backend: AnthropicBackend
    private let config: Config
    private let run: TabRun
    private var inFlight: Set<UUID> = []

    public init(backend: AnthropicBackend, config: Config = Config()) {
        self.backend = backend
        self.config = config
        run = TabRun(backend: backend, config: TabRun.Config(
            busySeenTimeout: config.busySeenTimeout, turnTimeout: config.turnTimeout,
            pollInterval: config.pollInterval, pingInterval: config.pingInterval,
            structuredOutputGrace: config.structuredOutputGrace, injectReadyTimeout: config.injectReadyTimeout,
            injectVerifyTimeout: config.injectVerifyTimeout, injectMaxAttempts: config.injectMaxAttempts))
    }

    /// Handle one parsed HTTP request; `emit` receives raw response bytes (a single
    /// buffered response, or — for streaming, Task 6 — head + SSE frames).
    public func handle(_ request: HTTPRequest, emit: @escaping (Data) -> Void) async {
        guard !request.looksBrowserOriginated else {
            emit(errorResponse(403, "permission_error", "cross-origin or non-loopback request refused"))
            return
        }
        guard request.method == "POST", request.path == "/v1/messages" else {
            emit(errorResponse(404, "not_found_error", "not found: \(request.method) \(request.path)"))
            return
        }
        let rawTab = request.headers[Self.tabNameHeader]?.trimmingCharacters(in: .whitespaces) ?? ""
        let rawSID = request.headers[Self.sessionIDHeader]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard rawTab.isEmpty != rawSID.isEmpty else {
            emit(errorResponse(400, "invalid_request_error",
                               "exactly one of \(Self.sessionIDHeaderWireName) or \(Self.tabNameHeaderWireName) is required"))
            return
        }
        guard let req = AnthropicMessagesRequest.decode(request.body) else {
            emit(errorResponse(400, "invalid_request_error", "could not parse request body"))
            return
        }
        if let soError = req.structuredOutputError {
            emit(errorResponse(400, "invalid_request_error", soError))
            return
        }
        if let message = req.clientToolsError ?? req.messageError {
            emit(errorResponse(400, "invalid_request_error", message))
            return
        }
        // Before a scratch tab is commissioned: a request that asks for both is neither
        // an API tool tab nor a structured-output turn.
        if req.structuredOutput != nil && req.clientTools != nil {
            emit(errorResponse(400, "invalid_request_error",
                               "structured output and client tools cannot be combined"))
            return
        }
        // Routing: a tab name must name an existing tab (fails as it always has); a
        // session id routes to whichever tab owns it — or creates a scratch tab for it.
        // NOTE: everything from here to `inFlight.insert` is synchronous on the main
        // actor, so a concurrent same-sid request resolves the freshly created tab and
        // hits the in-flight 529 — no separate creation lock is needed.
        let tab: AnthropicTab
        var commissionedTools = false
        let modelAlias = ScheduleModel(anthropicModel: req.model)?.rawValue
        if !rawTab.isEmpty {
            guard let named = backend.tab(named: rawTab) else {
                emit(errorResponse(404, "not_found_error",
                                   "tab '\(rawTab)' not found — \(Self.tabNameHeaderWireName) must name an Admiral tab"))
                return
            }
            tab = named
        } else {
            guard UUID(uuidString: rawSID) != nil else {
                emit(errorResponse(400, "invalid_request_error",
                                   "\(Self.sessionIDHeaderWireName) must be a UUID"))
                return
            }
            let sid = rawSID.lowercased()
            let cwdRaw = request.headers[Self.cwdHeader]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !cwdRaw.isEmpty else {
                emit(errorResponse(400, "invalid_request_error",
                                   "missing required header \(Self.cwdHeaderWireName) — required with \(Self.sessionIDHeaderWireName)"))
                return
            }
            if let existing = backend.tab(sessionID: sid) {
                tab = existing  // live sid wins; the cwd header is ignored (the tab has one)
            } else {
                let cwd = (cwdRaw as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                    emit(errorResponse(400, "invalid_request_error",
                                       "\(Self.cwdHeaderWireName) must be an existing directory: \(cwd)"))
                    return
                }
                commissionedTools = req.clientTools != nil
                guard let created = backend.createScratchTab(
                    sessionID: sid, cwd: cwd, model: modelAlias, clientTools: req.clientTools
                ) else {
                    emit(errorResponse(500, "api_error", "failed to create a session for \(sid)"))
                    return
                }
                tab = created
            }
        }
        guard tab.isManaged else {
            emit(errorResponse(400, "invalid_request_error", "tab is not a managed claude session"))
            return
        }
        guard !inFlight.contains(tab.id) else {
            emit(errorResponse(529, "overloaded_error", "a request for this tab is already in flight"))
            return
        }
        inFlight.insert(tab.id)
        defer { inFlight.remove(tab.id) }

        let toolMode = backend.clientToolsEnabled(tabID: tab.id)
        if req.structuredOutput != nil && (req.clientTools != nil || toolMode) {
            emit(errorResponse(400, "invalid_request_error",
                               "structured output and client tools cannot be combined"))
            return
        }

        // Arm the structured-output tripwire before waiting on the tab or injecting — it
        // owns this request for its whole lifecycle, and the defer clears it on every exit
        // path (busy-gate 529, no-delta 400, timeout, success). Per design §4.2 arming
        // happens "before injecting the prompt".
        if let spec = req.structuredOutput {
            backend.armStructuredOutput(tabID: tab.id, spec: spec)
        }
        defer { if req.structuredOutput != nil { backend.clearStructuredOutput(tabID: tab.id, type: .api) } }

        if req.clientTools != nil || toolMode || !req.trailingToolResults.isEmpty {
            await handleClientTools(req, tab: tab, commissionedTools: commissionedTools, emit: emit)
            return
        }

        // Busy gate: only .busy blocks — a freshly spawned claude has no status file yet.
        let gateDeadline = Date().addingTimeInterval(config.busyWaitTimeout)
        while backend.liveStatus(tabID: tab.id) == .busy {
            guard Date() < gateDeadline else {
                emit(errorResponse(529, "overloaded_error", "tab is busy"))
                return
            }
            await sleepPoll()
        }

        // We need the transcript's location to diff history and capture the reply. For a
        // managed tab this is always known (deterministic from the session id), even for a
        // brand-new tab whose file doesn't exist yet — a missing file just means empty
        // history, and injecting the first message is what creates it.
        var path = backend.transcriptPath(tabID: tab.id)
        for _ in 0..<5 where path == nil {
            await sleepPoll()
            path = backend.transcriptPath(tabID: tab.id)
        }
        guard let path else {
            emit(errorResponse(500, "api_error", "transcript path for this tab is not available"))
            return
        }
        let snapshot = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()

        let delta = TurnCapture.unseen(requestTexts: req.userTexts,
                                       transcriptTexts: TurnCapture.userTexts(in: snapshot))
        guard !delta.isEmpty else {
            emit(errorResponse(400, "invalid_request_error", "no new user message for this tab"))
            return
        }

        // Wait for claude to boot, type the prompt, and confirm the transcript gained it
        // (`TabRun.deliver`). If it never lands, the turn timeouts below still govern.
        await run.deliver(delta.joined(separator: "\n\n"), tabID: tab.id, path: path,
                          baselineUserCount: TurnCapture.userTexts(in: snapshot).count)
        let messageID = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        let structured = req.structuredOutput != nil
        if req.stream {
            emit(HTTPWire.sseHead())
            emit(HTTPWire.sseFrame(event: "message_start",
                                   data: AnthropicWire.messageStart(id: messageID, model: req.model)))
            // For SO requests the visible turn text is scaffolding, not the answer — no
            // text block is opened and nothing streams until the result exists.
            if !structured {
                emit(HTTPWire.sseFrame(event: "content_block_start",
                                       data: AnthropicWire.contentBlockStart()))
            }
            let result = await run.awaitTurn(tabID: tab.id, path: path, fromOffset: snapshot.count,
                                             slot: structured ? .api : nil) { chunk in
                if !structured {
                    emit(HTTPWire.sseFrame(event: "content_block_delta",
                                           data: AnthropicWire.contentBlockDelta(text: chunk)))
                }
            } onPing: {
                emit(HTTPWire.sseFrame(event: "ping", data: AnthropicWire.ping()))
            }
            let usage = result.usage ?? AnthropicUsage(inputTokens: 0, outputTokens: 0)
            if let spec = req.structuredOutput {
                guard let value = resolvedStructuredResult(tabID: tab.id) else {
                    emit(HTTPWire.sseFrame(event: "error", data: AnthropicWire.error(
                        type: "api_error",
                        message: "structured output failed after \(StructuredOutputState.maxAttempts) attempts")))
                    return
                }
                emitStructuredBlocks(spec: spec, result: value, messageID: messageID, emit: emit)
                emit(HTTPWire.sseFrame(event: "message_delta", data: AnthropicWire.messageDelta(
                    usage: usage, stopReason: spec.delivery == .toolUse ? "tool_use" : "end_turn")))
                emit(HTTPWire.sseFrame(event: "message_stop", data: AnthropicWire.messageStop()))
            } else {
                emit(HTTPWire.sseFrame(event: "content_block_stop", data: AnthropicWire.contentBlockStop()))
                emit(HTTPWire.sseFrame(event: "message_delta",
                                       data: AnthropicWire.messageDelta(usage: usage)))
                emit(HTTPWire.sseFrame(event: "message_stop", data: AnthropicWire.messageStop()))
            }
        } else {
            let result = await run.awaitTurn(tabID: tab.id, path: path, fromOffset: snapshot.count,
                                             slot: structured ? .api : nil)
            let usage = result.usage ?? AnthropicUsage(inputTokens: 0, outputTokens: 0)
            if let spec = req.structuredOutput {
                guard let value = resolvedStructuredResult(tabID: tab.id) else {
                    emit(errorResponse(500, "api_error",
                        "structured output failed after \(StructuredOutputState.maxAttempts) attempts"))
                    return
                }
                emit(HTTPWire.response(status: 200, body: AnthropicWire.structuredMessage(
                    id: messageID, model: req.model, spec: spec, result: value, usage: usage)))
            } else {
                emit(HTTPWire.response(status: 200, body: AnthropicWire.message(
                    id: messageID, model: req.model, text: result.text, usage: usage)))
            }
        }
    }

    /// A turn on an API tool tab, or any request that carries `tool_result`s.
    ///
    /// A matching tool_result set fulfills the parked MCP calls and skips the busy gate:
    /// Claude is blocked inside those calls, so the tab stays `.busy` until the results
    /// land. Plain text or a partial result set is a 400 and does not type into the tab.
    private func handleClientTools(_ req: AnthropicMessagesRequest, tab: AnthropicTab,
                                   commissionedTools: Bool, emit: @escaping (Data) -> Void) async {
        if let message = req.clientToolsError ?? req.messageError {
            emit(errorResponse(400, "invalid_request_error", message))
            return
        }
        let toolMode = backend.clientToolsEnabled(tabID: tab.id)
        if let tools = req.clientTools {
            guard toolMode || commissionedTools else {
                emit(errorResponse(400, "invalid_request_error",
                                   "client tools require an API scratch session commissioned with tools "
                                   + "(\(Self.sessionIDHeaderWireName))"))
                return
            }
            // The create request already wrote the catalog inside commission, before spawn.
            if !commissionedTools {
                backend.installClientTools(tabID: tab.id, tools: tools)
            }
        }
        guard let token = backend.sessionToken(tabID: tab.id) else {
            emit(errorResponse(500, "api_error", "session token for this tab is not available"))
            return
        }

        let broker = backend.clientToolBroker
        var fulfillment: [ClientToolResultBlock]?
        let outstanding = broker.outstanding(token: token)
        if !outstanding.isEmpty {
            switch ClientToolContinuation.decide(
                outstanding: outstanding, results: req.trailingToolResults,
                lastUserMessageHasText: req.trailingUserHasText) {
            case let .reject(message):
                emit(errorResponse(400, "invalid_request_error", message))
                return
            case let .match(blocks):
                fulfillment = blocks
            }
        } else if !req.trailingToolResults.isEmpty && !req.trailingUserHasText {
            emit(errorResponse(400, "invalid_request_error", ClientToolContinuation.noneOutstanding))
            return
        } else {
            let gateDeadline = Date().addingTimeInterval(config.busyWaitTimeout)
            while backend.liveStatus(tabID: tab.id) == .busy {
                guard Date() < gateDeadline else {
                    emit(errorResponse(529, "overloaded_error", "tab is busy"))
                    return
                }
                await sleepPoll()
            }
        }

        var path = backend.transcriptPath(tabID: tab.id)
        for _ in 0..<5 where path == nil {
            await sleepPoll()
            path = backend.transcriptPath(tabID: tab.id)
        }
        guard let path else {
            emit(errorResponse(500, "api_error", "transcript path for this tab is not available"))
            return
        }
        let snapshot = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()

        if let blocks = fulfillment {
            guard broker.fulfillAll(token: token, blocks: blocks) else {
                emit(errorResponse(500, "api_error", "failed to deliver tool results"))
                return
            }
        } else {
            let delta = TurnCapture.unseen(requestTexts: req.userTexts,
                                           transcriptTexts: TurnCapture.userTexts(in: snapshot))
            guard !delta.isEmpty else {
                emit(errorResponse(400, "invalid_request_error", "no new user message for this tab"))
                return
            }
            await run.deliver(delta.joined(separator: "\n\n"), tabID: tab.id, path: path,
                              baselineUserCount: TurnCapture.userTexts(in: snapshot).count)
        }

        let messageID = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        if req.stream {
            emit(HTTPWire.sseHead())
            emit(HTTPWire.sseFrame(event: "message_start",
                                   data: AnthropicWire.messageStart(id: messageID, model: req.model)))
        }
        let outcome = await awaitClientTurn(tabID: tab.id, token: token, path: path,
                                            fromOffset: snapshot.count) {
            if req.stream {
                emit(HTTPWire.sseFrame(event: "ping", data: AnthropicWire.ping()))
            }
        }
        switch outcome {
        case let .failed(message):
            if req.stream {
                emit(HTTPWire.sseFrame(event: "error",
                                       data: AnthropicWire.error(type: "api_error", message: message)))
            } else {
                emit(errorResponse(500, "api_error", message))
            }
        case let .tools(text, usage, calls):
            let usage = usage ?? AnthropicUsage(inputTokens: 0, outputTokens: 0)
            if req.stream {
                emitClientToolStream(text: text, calls: calls, usage: usage, stopReason: "tool_use", emit: emit)
            } else {
                emit(HTTPWire.response(status: 200, body: AnthropicWire.toolUseMessage(
                    id: messageID, model: req.model, text: text, calls: calls, usage: usage)))
            }
        case let .text(text, usage):
            let usage = usage ?? AnthropicUsage(inputTokens: 0, outputTokens: 0)
            if req.stream {
                emitClientToolStream(text: text, calls: [], usage: usage, stopReason: "end_turn", emit: emit)
            } else {
                emit(HTTPWire.response(status: 200, body: AnthropicWire.message(
                    id: messageID, model: req.model, text: text, usage: usage)))
            }
        }
    }

    private enum ClientTurnOutcome {
        case text(String, AnthropicUsage?)
        case tools(String, AnthropicUsage?, [TurnCapture.ToolUse])
        case failed(String)
    }

    /// Poll the bytes appended after this request started. Read the transcript before
    /// live status so a tool_use line written as the prompt landed can correlate on the
    /// first pass. A complete parked set returns while the tab is still busy.
    private func awaitClientTurn(tabID: UUID, token: String, path: String, fromOffset: Int,
                                 onPing: () -> Void) async -> ClientTurnOutcome {
        let started = Date()
        var sawBusy = false
        var text = ""
        var usage: AnthropicUsage?
        var lastActivity = Date()
        let notParked = "client tool call was not parked"
        while true {
            var pending = false
            if let tail = TabRun.readTail(path: path, fromOffset: fromOffset) {
                let uses = TurnCapture.toolUses(in: tail)
                if !uses.isEmpty {
                    switch backend.clientToolBroker.correlate(token: token, uses: uses) {
                    case let .ready(calls):
                        let captured = TurnCapture.capture(tail, fromOffset: 0)
                        return .tools(captured.text, captured.usage ?? usage, calls)
                    case .waiting:
                        pending = true
                    }
                }
                let captured = TurnCapture.capture(tail, fromOffset: 0)
                text = captured.text
                if let next = captured.usage { usage = next }
            }
            if Date().timeIntervalSince(lastActivity) > config.pingInterval {
                onPing()
                lastActivity = Date()
            }
            let status = backend.liveStatus(tabID: tabID)
            if status == .busy { sawBusy = true }
            let elapsed = Date().timeIntervalSince(started)
            if pending, status == .idle, elapsed > config.busySeenTimeout {
                backend.clientToolBroker.failUncorrelated(token: token, message: notParked)
                return .failed(notParked)
            }
            if !pending, sawBusy, status == .idle { return .text(text, usage) }
            if !pending, !sawBusy, elapsed > config.busySeenTimeout, !text.isEmpty, status == .idle {
                return .text(text, usage)
            }
            if elapsed > config.turnTimeout {
                if pending {
                    backend.clientToolBroker.failUncorrelated(token: token, message: notParked)
                    return .failed(notParked)
                }
                return .text(text, usage)
            }
            await sleepPoll()
        }
    }

    /// Client-tool SSE body, emitted once the turn resolved. No text block is opened
    /// up front: the tool calls are the message, and a leading text block would take
    /// index 0 before the turn's content is known.
    private func emitClientToolStream(text: String, calls: [TurnCapture.ToolUse],
                                      usage: AnthropicUsage, stopReason: String,
                                      emit: (Data) -> Void) {
        var index = 0
        if calls.isEmpty || !text.isEmpty {
            emit(HTTPWire.sseFrame(event: "content_block_start",
                                   data: AnthropicWire.contentBlockStart(index: index)))
            if !text.isEmpty {
                emit(HTTPWire.sseFrame(event: "content_block_delta",
                                       data: AnthropicWire.contentBlockDelta(text: text, index: index)))
            }
            emit(HTTPWire.sseFrame(event: "content_block_stop",
                                   data: AnthropicWire.contentBlockStop(index: index)))
            index += 1
        }
        for call in calls {
            emit(HTTPWire.sseFrame(event: "content_block_start",
                                   data: AnthropicWire.contentBlockStartToolUse(
                                    id: call.id, name: call.name, index: index)))
            emit(HTTPWire.sseFrame(event: "content_block_delta",
                                   data: AnthropicWire.inputJSONDelta(
                                    partial: AnthropicWire.jsonText(call.input), index: index)))
            emit(HTTPWire.sseFrame(event: "content_block_stop",
                                   data: AnthropicWire.contentBlockStop(index: index)))
            index += 1
        }
        emit(HTTPWire.sseFrame(event: "message_delta",
                               data: AnthropicWire.messageDelta(usage: usage, stopReason: stopReason)))
        emit(HTTPWire.sseFrame(event: "message_stop", data: AnthropicWire.messageStop()))
    }

    /// The fulfilled structured result for this tab, or nil when the tripwire never
    /// resolved (still armed / failed / no result). Both response paths ask this one
    /// question, then turn nil into their own channel's "structured output failed" error.
    private func resolvedStructuredResult(tabID: UUID) -> JSONValue? {
        guard let state = backend.structuredOutputState(tabID: tabID, type: .api),
              state.status == .fulfilled else { return nil }
        return state.result
    }

    /// SSE frames for a fulfilled structured result — one block, emitted whole once the
    /// turn resolved (there is nothing to stream incrementally; the result exists only
    /// after set_structured_output succeeds).
    private func emitStructuredBlocks(spec: StructuredOutputSpec, result: JSONValue,
                                      messageID: String, emit: (Data) -> Void) {
        switch spec.delivery {
        case .jsonText:
            emit(HTTPWire.sseFrame(event: "content_block_start", data: AnthropicWire.contentBlockStart()))
            emit(HTTPWire.sseFrame(event: "content_block_delta",
                                   data: AnthropicWire.contentBlockDelta(text: AnthropicWire.jsonText(result))))
            emit(HTTPWire.sseFrame(event: "content_block_stop", data: AnthropicWire.contentBlockStop()))
        case .toolUse:
            emit(HTTPWire.sseFrame(event: "content_block_start",
                data: AnthropicWire.contentBlockStartToolUse(
                    id: "toolu_" + String(messageID.dropFirst(4)),
                    name: spec.toolName ?? "structured_output")))
            emit(HTTPWire.sseFrame(event: "content_block_delta",
                data: AnthropicWire.inputJSONDelta(partial: AnthropicWire.jsonText(result))))
            emit(HTTPWire.sseFrame(event: "content_block_stop", data: AnthropicWire.contentBlockStop()))
        }
    }

    private func sleepPoll() async {
        try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
    }

    private func errorResponse(_ status: Int, _ type: String, _ message: String) -> Data {
        HTTPWire.response(status: status, body: AnthropicWire.error(type: type, message: message))
    }
}
