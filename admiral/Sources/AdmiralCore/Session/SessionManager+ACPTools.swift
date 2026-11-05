import Foundation

/// What Settings → Agents' **Test connection** found: what the agent negotiated in
/// `initialize`, with the exec probes, as the record a tab on it would start with — or why
/// it could not be reached, with the log that holds the agent's own words.
public enum AcpConnectionTestResult: Equatable, Sendable {
    case connected(AcpCapabilityRecord)
    case failed(message: String, log: URL)
}

/// The two ACP actions that only look before a tab exists: testing an agent's connection,
/// and opening one of its sessions picked from **Import sessions…**.
extension SessionManager {
    /// How long Test connection waits on `initialize` before giving up on the agent.
    nonisolated static let connectionTestTimeout: UInt64 = 15_000_000_000

    /// Spawn the agent, `initialize` ONLY — never `session/new`, which would start its MCP
    /// servers and hooks just to look — then end it, and run the exec probes (git, gh, gh
    /// auth) in its environment. The traffic and the agent's stderr go to
    /// `<base>/acp/test-<agent id>.log`; a failure carries its last line (stderr, or
    /// non-JSON stdout) and a PATH hint on a command not found.
    public func testACPConnection(_ agent: AcpAgentConfig) async -> AcpConnectionTestResult {
        let logURL = Self.acpLogURL(base: supportDir, session: "test-\(agent.id.uuidString.lowercased())")
        let logStart = AcpLog.size(logURL)
        func failed(_ reason: String) -> AcpConnectionTestResult {
            AcpLog.append("acp: connection test failed: \(reason)", to: logURL)
            let message = AcpLog.failureReason(reason, log: logURL, after: logStart, command: agent.launch.command)
            return .failed(message: message, log: logURL)
        }
        let transport: AcpTransport
        do {
            transport = try acpTransportFactory(agent, logURL)
        } catch {
            return failed("could not launch \(agent.name): \(error)")
        }
        let connection = JSONRPCConnection(
            transport: transport, traceTraffic: true, log: { AcpLog.append($0, to: logURL) })
        await connection.start()
        let watchdog = Task {
            try await Task.sleep(nanoseconds: Self.connectionTestTimeout)
            await connection.close()
        }
        let caps: AcpCapabilities?
        let failure: String?
        do {
            caps = AcpCapabilities(initializeResult: try await connection.request(
                "initialize", params: AcpClient.initializeParams()))
            failure = nil
        } catch let error as JSONRPCError {
            caps = nil
            failure = error == .closed ? "the agent exited or did not answer initialize" : error.message
        } catch {
            caps = nil
            failure = "\(error)"
        }
        watchdog.cancel()
        await connection.close()
        guard let caps else { return failed(failure ?? "initialize failed") }

        let runner = acpRunnerFactory(agent)
        let cwd = agent.cwd
        let probed = await Task.detached(priority: .userInitiated) {
            AcpCapabilityRecord.probe(runner: runner, cwd: cwd)
        }.value
        return .connected(AcpCapabilityRecord(
            negotiated: caps, hasExec: runner != nil, bridgeRunning: sessionBridgeRunning(),
            git: probed.git, gh: probed.gh, ghAuthed: probed.ghAuthed))
    }

    /// Open a session picked from Import sessions… on `agent` — idempotent: a tab already
    /// holding that agent session is selected instead of a second one being opened. A new tab
    /// restores it (`session/resume`, else `session/load`), named after its title.
    @discardableResult
    public func openImportedACP(agent: AcpAgentConfig, acpSessionID: String, title: String?) -> AgentSession {
        if let open = sessions.first(where: {
            $0.backend == .acp(agentName: agent.name) && $0.acpSessionID == acpSessionID
        }) {
            selectedID = open.id
            return open
        }
        let name = title.map { String($0.prefix(40)) } ?? agent.name
        return commissionACP(agent: agent, callsign: name, start: .restore(acpSessionID: acpSessionID))
    }
}
