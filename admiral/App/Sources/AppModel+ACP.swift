import AppKit
import AdmiralCore

/// ACP agents in the app: opening tabs on them (New-session form, Import sessions…), Test
/// connection, and the per-tab log. The decisions live in Core (`SessionManager+ACP*`); this
/// only wires them to the UI.
extension AppModel {
    var acpAgents: [AcpAgentConfig] { acpAgentStore.load() }

    /// A new ACP tab from the New-session form, named as typed (locked, like a claude tab's).
    func newACPSession(agent: AcpAgentConfig, name: String, cwd: String, scratch: Bool) {
        let callsign = name.trimmingCharacters(in: .whitespaces)
        let session = sessions.commissionACP(
            agent: agent, callsign: callsign.isEmpty ? agent.name : callsign, cwd: cwd, scratch: scratch)
        if !callsign.isEmpty { sessions.rename(session.id, to: callsign) }
        if scratch { selectTerminal(session.id) }
    }

    /// Import sessions…'s Open: a new tab restoring it, or the tab that already holds it.
    func openImportedACP(agent: AcpAgentConfig, acpSessionID: String, title: String?) {
        let session = sessions.openImportedACP(agent: agent, acpSessionID: acpSessionID, title: title)
        selectTerminal(session.id)
    }

    func testACPConnection(_ agent: AcpAgentConfig) async -> AcpConnectionTestResult {
        let result = await sessions.testACPConnection(agent)
        acpConnectionTests[agent.id] = result
        return result
    }

    /// Whether `agent` lists its sessions, from what it last negotiated — an open tab on it, or
    /// a Test connection. Nil = not known yet (nothing has spoken to it this run).
    func acpListsSessions(_ agent: AcpAgentConfig) -> Bool? {
        if let record = sessions.sessions.first(where: {
            $0.backend == .acp(agentName: agent.name) && $0.acpCapabilities != nil
        })?.acpCapabilities {
            return record.isEnabled(.importSessions)
        }
        if case let .connected(record)? = acpConnectionTests[agent.id] { return record.isEnabled(.importSessions) }
        return nil
    }

    /// The composer's option picker. Nil = done, or superseded by a newer pick on the same tab
    /// (its error would be stale); otherwise the text to show in the composer.
    func setACPConfigOption(_ session: AgentSession, id: String, value: String) async -> String? {
        let pick = (acpOptionPicks[session.id] ?? 0) + 1
        acpOptionPicks[session.id] = pick
        let error = await sessions.setACPConfigOption(session.id, id: id, value: value)
        return acpOptionPicks[session.id] == pick ? error : nil
    }

    /// The tab menu's Show ACP log.
    func showACPLog(_ session: AgentSession) { acpLogSession = session }

    func acpLogURL(for session: AgentSession) -> URL? {
        session.claudeSessionID.map { SessionManager.acpLogURL(base: sessions.supportDir, session: $0) }
    }

    /// Why Fork is off for `session`, or nil when it can fork. A PTY tab always can; an ACP tab
    /// by its capability record — the same answer `SessionManager.forkACP` gates on.
    func forkDisabledReason(_ session: AgentSession) -> String? {
        guard session.backend != .pty else { return nil }
        guard let record = session.acpCapabilities else {
            return session.connectError == nil ? "The agent is still connecting" : "The agent is not running"
        }
        return record.reason(.fork)
    }
}
