import Foundation

/// What launch-time restore does with one saved record. Decided here, in Core, so the app's
/// restore loop only acts on it — and so the order of the checks is under test: an ACP record
/// is decided before the Mac folder check, because its cwd is a path as the AGENT sees it
/// (`/workspace` in a container) and is normally absent on this Mac.
public enum RestorePlan: Equatable {
    /// Reopen on that agent with `.restore(acpSessionID:)`.
    case acp(agent: AcpAgentConfig, acpSessionID: String)
    /// Reopen in a PTY; `resume` when claude has a transcript for the id (never for bash).
    case pty(resume: Bool)
    /// Leave it closed (the record stays, so it comes back once the cause is fixed).
    case skip(reason: String)
}

/// ACP tabs: an agent spoken to over JSON-RPC instead of a claude in a PTY. The tab's kind is
/// decided once, here, by which driver it gets (`AcpSessionController`); every input funnel
/// then routes through that driver like any other tab's.
///
/// All Admiral state (appearance, goals, chat ledger, footprint, mirror, log, restore record)
/// stays keyed by the tab's LOCAL `claudeSessionID`; `acpSessionID` is only ever sent to the agent.
extension SessionManager {
    /// `<base>/acp/<session>.log`: the agent's stderr, the connection's stray lines, and
    /// Admiral's notes on the tab (a failed handshake, input that never went out).
    nonisolated public static func acpLogURL(base: URL, session: String) -> URL {
        AcpLog.url(base: base, session: session)
    }

    /// A configured agent by name (case-insensitive, like `AcpAgentStore.agent(named:)`).
    func acpAgent(named name: String) -> AcpAgentConfig? {
        acpAgents().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// An ACP tab's controller — the one place a driver is asked what kind it is (like
    /// `handle(for:)` for a PTY), for the agent's negotiated capabilities.
    func acpController(for id: UUID) -> AcpSessionController? { drivers[id] as? AcpSessionController }

    /// Open an ACP tab on `agent`, synchronously: the tab exists at once (status `.unknown`),
    /// the handshake runs in a `Task`, and the controller pushes status from then on.
    ///
    /// - `cwd`: the folder as the agent sees it; nil = the agent's default.
    /// - `start`: a new agent session, a restore (`session/resume`, else `session/load`) or a fork.
    /// - `sessionID`: the local id to reuse (restore / reload / fork); nil = a fresh one.
    ///
    /// The restore record is written once the agent names its session (`sessionStarted`), not
    /// here — until then there is nothing to resume. A launch that throws (the command is not
    /// there) still opens the tab, dead (`.shell`), with the reason in its ACP log.
    @discardableResult
    public func commissionACP(
        agent: AcpAgentConfig, callsign: String, cwd: String? = nil,
        start: AcpSessionController.Start = .new, scratch: Bool = false,
        sessionID: String? = nil, teamName: String? = nil
    ) -> AgentSession {
        let cwd = cwd ?? agent.cwd
        let sessionID = sessionID ?? UUID().uuidString.lowercased()
        let mirrorURL = TranscriptMirror.url(base: supportDir, session: sessionID)
        let logURL = Self.acpLogURL(base: supportDir, session: sessionID)
        let appearance = appearanceStore.appearance(forSession: sessionID)
        let label = teamName?.trimmingCharacters(in: .whitespaces)
        var session = AgentSession(
            callsign: Self.resolvedCallsign(callsign, cwd: cwd), agentType: .acp(agentName: agent.name),
            cwd: cwd, teamName: (label?.isEmpty ?? true) ? nil : label,
            claudeSessionID: sessionID, spawnedAt: Date(), transcriptPath: mirrorURL.path,
            status: .unknown, customName: appearance.name, avatarColorHex: appearance.colorHex,
            avatarSymbol: appearance.symbol, scratch: scratch)
        session.backend = .acp(agentName: agent.name)
        if case let .restore(acpSessionID) = start { session.acpSessionID = acpSessionID }
        session.touchedRepos = touchedReposStore.repos(forSession: sessionID)
        let id = session.id

        var config = agent
        config.cwd = cwd
        // This launch's stretch of the log (it accumulates across reloads), for the failure reason.
        let logStart = AcpLog.size(logURL)
        var controller: AcpSessionController?
        do {
            let transport = try acpTransportFactory(config, logURL)
            let connection = JSONRPCConnection(transport: transport, log: { AcpLog.append($0, to: logURL) })
            let box = WeakController()
            let hooks = AcpHookAdapter(
                base: supportDir, token: session.token, sessionID: sessionID, cwd: cwd,
                runner: acpRunnerFactory(agent),
                transcriptPath: mirrorURL.path)
            let made = AcpSessionController(
                config: config, connection: connection,
                mirror: TranscriptMirror(url: mirrorURL, sessionID: sessionID, cwd: cwd),
                mcpServer: sessionBridge?(session.token), hooks: hooks,
                events: acpEvents(id, controller: box, logURL: logURL, logStart: logStart),
                // `session/load` replays the whole history. The mirror already holds it (same
                // local id, same file), so the replay is dropped — unless the file is gone, in
                // which case the replay is what rebuilds the Chat history.
                replayIntoMirror: !FileManager.default.fileExists(atPath: mirrorURL.path))
            box.value = made
            controller = made
        } catch {
            AcpLog.append("acp: could not launch \(agent.name): \(error)", to: logURL)
            session.status = .shell
            session.connectError = "could not launch \(agent.name): \(error)"
        }

        install(session, driver: controller)
        if let controller { Task { await controller.start(start) } }
        return session
    }

    /// The controller's events, into this tab. Weak both ways: the manager owns the controller
    /// (through `drivers`), and the controller owns these closures.
    private func acpEvents(
        _ id: UUID, controller: WeakController, logURL: URL, logStart: UInt64
    ) -> AcpSessionController.Events {
        AcpSessionController.Events(
            status: { [weak self] in self?.applyStatus($0, to: id) },
            phase: { [weak self] phase in
                self?.acpPhaseChanged(id, phase, controller: controller.value, logURL: logURL, logStart: logStart)
            },
            sessionStarted: { [weak self] acpSessionID, caps, _ in
                self?.acpSessionStarted(id, acpSessionID, capabilities: caps)
            },
            update: { [weak self] _ in self?.update(id) { $0.lastActivityAt = Date() } })
    }

    /// The agent named its session: remember it (and what it negotiated) on the tab, probe its
    /// environment, and — unless scratch — write the restore record, keeping the tab list's
    /// order (the upsert appends).
    private func acpSessionStarted(_ id: UUID, _ acpSessionID: String, capabilities: AcpCapabilities) {
        update(id) {
            $0.acpSessionID = acpSessionID
            $0.connectError = nil
        }
        let hasExec = sessions.first(where: { $0.id == id }).flatMap(acpRunner(for:)) != nil
        update(id) { $0.acpCapabilities = AcpCapabilityRecord(negotiated: capabilities, hasExec: hasExec) }
        probeEnvironment(id)
        guard let s = sessions.first(where: { $0.id == id }), !s.scratch else { return }
        persistRecord(of: s)
        openSessionsStore.reorder(sessions.compactMap(\.claudeSessionID))
    }

    /// A failed handshake ends the agent's process and leaves the tab dead; an ended connection
    /// is already dead. Either way the tab records why (`connectError`, with the agent's last
    /// stderr line from this launch), and input still queued — which would otherwise vanish
    /// without a word — is written to the tab's ACP log. A failure is reported once: the
    /// `.ended` that follows a `.failed` adds nothing.
    private func acpPhaseChanged(
        _ id: UUID, _ phase: AcpSessionController.Phase, controller: AcpSessionController?,
        logURL: URL, logStart: UInt64
    ) {
        let state: String
        let reason: String
        switch phase {
        case .connecting, .ready:
            return
        case let .failed(message):
            AcpLog.append("acp: session failed: \(message)", to: logURL)
            state = "failed"
            reason = message
            controller?.terminate()
            applyStatus(.shell, to: id)
        case .ended:
            guard sessions.first(where: { $0.id == id })?.connectError == nil else { return }
            AcpLog.append("acp: agent connection closed", to: logURL)
            state = "ended"
            reason = "the agent exited"
        }
        let stderr = AcpLog.lastAgentLine(logURL, after: logStart)
        update(id) { $0.connectError = stderr.map { "\(reason): \($0)" } ?? reason }
        for text in controller?.queued ?? [] {
            AcpLog.append("acp: not delivered (session \(state)): \(text)", to: logURL)
        }
    }

    /// `git`/`gh`/`gh auth` in the agent's environment, off the main actor (each bounded at
    /// 5 s), into the tab's capability record. No exec = nothing to run: the record stays unprobed.
    private func probeEnvironment(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }),
              let runner = acpRunner(for: session) else { return }
        let cwd = session.cwd
        Task.detached(priority: .utility) { [weak self] in
            let probed = AcpCapabilityRecord.probe(runner: runner, cwd: cwd)
            await MainActor.run {
                self?.update(id) {
                    $0.acpCapabilities?.git = probed.git
                    $0.acpCapabilities?.gh = probed.gh
                    $0.acpCapabilities?.ghAuthed = probed.ghAuthed
                }
            }
        }
    }

    /// How this tab reads git, and how often — decided here, once per tab kind: a PTY tab asks
    /// the Mac every 2 s (as it always has); an ACP tab asks its agent's environment through
    /// exec, every 5 s (each call is a `docker exec`), and only once the probe found git there.
    /// Nil = no git to ask; the branch is left alone rather than read from the wrong machine.
    func gitAccess(for session: AgentSession) -> (runner: CommandRunner, interval: TimeInterval)? {
        guard session.backend != .pty else { return (LocalCommandRunner(), 2) }
        guard session.acpCapabilities?.isEnabled(.branch) == true,
              let runner = acpRunner(for: session) else { return nil }
        return (runner, 5)
    }

    /// The runner into an ACP tab's environment (its agent's exec command, via
    /// `acpRunnerFactory`); nil on a PTY tab, or when the agent has no exec or is gone.
    public func acpRunner(for session: AgentSession) -> CommandRunner? {
        guard case let .acp(agentName) = session.backend else { return nil }
        return acpAgent(named: agentName).flatMap(acpRunnerFactory)
    }

    /// An ACP fork: only when the agent advertised `session/fork`, else a no-op. The source's
    /// mirror is copied to the fork's, so its Chat starts with the shared history (the agent
    /// replays none on fork).
    func forkACP(_ source: AgentSession, agentName: String) {
        guard let sourceACP = source.acpSessionID,
              acpController(for: source.id)?.capabilities?.fork == true,
              let sourceSID = source.claudeSessionID,
              let agent = acpAgent(named: agentName) else { return }
        let newID = UUID().uuidString.lowercased()
        try? FileManager.default.copyItem(
            at: TranscriptMirror.url(base: supportDir, session: sourceSID),
            to: TranscriptMirror.url(base: supportDir, session: newID))
        let fork = commissionACP(
            agent: agent, callsign: source.callsign, cwd: source.cwd,
            start: .fork(acpSessionID: sourceACP), sessionID: newID, teamName: source.teamName)
        settleFork(fork.id, of: source.id, title: source.displayTitle,
                   color: source.avatarColorHex, symbol: source.avatarSymbol)
    }

    // MARK: - Restore

    /// How launch-time restore treats `record`. ACP first — its cwd is the agent's, so the Mac
    /// folder check would drop every container tab; an unknown agent is skipped (and the record
    /// kept, so re-adding the agent brings the tab back).
    public func restorePlan(for record: OpenSessionRecord) -> RestorePlan {
        if let agentName = record.acpAgentName {
            guard let agent = acpAgent(named: agentName) else {
                return .skip(reason: "no ACP agent named \"\(agentName)\" is configured")
            }
            guard let acpSessionID = record.acpSessionID else {
                return .skip(reason: "ACP record for \"\(agentName)\" has no agent session id")
            }
            return .acp(agent: agent, acpSessionID: acpSessionID)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.cwd, isDirectory: &isDir), isDir.boolValue else {
            return .skip(reason: "folder \(record.cwd) is gone")
        }
        return .pty(resume: !record.isBash && hasTranscript(sessionID: record.sessionID, cwd: record.cwd))
    }

    /// Reopen a saved ACP tab (a `.acp` restore plan) at its local id.
    @discardableResult
    public func restoreACP(_ record: OpenSessionRecord, agent: AcpAgentConfig, acpSessionID: String) -> AgentSession {
        commissionACP(agent: agent, callsign: record.callsign, cwd: record.cwd,
                      start: .restore(acpSessionID: acpSessionID),
                      sessionID: record.sessionID, teamName: record.teamName)
    }

    // MARK: - Import

    /// The agent's sessions in `agent.cwd` (`session/list`, every page) that no open tab on this
    /// agent already holds. A short-lived connection — initialize, list, terminate — and never
    /// `session/new`, which would create a session just to look. Empty when the agent does not
    /// advertise listing, cannot be launched, or does not answer within 15 s.
    public func importACPSessions(agent: AcpAgentConfig) async -> [(acpSessionID: String, title: String?)] {
        let logURL = Self.acpLogURL(base: supportDir, session: "import-\(agent.id.uuidString.lowercased())")
        let transport: AcpTransport
        do {
            transport = try acpTransportFactory(agent, logURL)
        } catch {
            AcpLog.append("acp: could not launch \(agent.name) to list sessions: \(error)", to: logURL)
            return []
        }
        let connection = JSONRPCConnection(transport: transport, log: { AcpLog.append($0, to: logURL) })
        await connection.start()
        // A hung agent must not hang the caller: closing fails every pending request.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            await connection.close()
        }
        var found: [(acpSessionID: String, title: String?)] = []
        do {
            let caps = AcpCapabilities(initializeResult: try await connection.request(
                "initialize", params: AcpClient.initializeParams()))
            var cursor: String?
            var pages = 0
            while caps.list, pages < 50 {
                pages += 1
                let page = try await connection.request(
                    "session/list", params: AcpClient.listSessionsParams(cwd: agent.cwd, cursor: cursor))
                for entry in page["sessions"]?.arrayValue ?? [] {
                    guard let id = entry["sessionId"]?.stringValue else { continue }
                    found.append((id, entry["title"]?.stringValue))
                }
                guard let next = page["nextCursor"]?.stringValue, !next.isEmpty else { break }
                cursor = next
            }
        } catch {
            AcpLog.append("acp: listing sessions failed: \(error)", to: logURL)
        }
        watchdog.cancel()
        await connection.close()
        let open = Set(sessions.filter { $0.backend == .acp(agentName: agent.name) }.compactMap(\.acpSessionID))
        return found.filter { !open.contains($0.acpSessionID) }
    }
}

/// The controller an `Events` closure reports for, set once it exists (the events are built
/// before it). Weak: the manager's `drivers` map is the owner.
@MainActor
private final class WeakController {
    weak var value: AcpSessionController?
}
