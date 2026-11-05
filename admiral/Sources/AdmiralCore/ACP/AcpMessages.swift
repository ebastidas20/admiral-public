import Foundation

/// Builders for the `params` of the requests Admiral (the ACP client) sends.
public enum AcpClient {
    /// Advertises exactly elicitation, compaction and terminal_output. Never `fs` or `terminal`:
    /// Admiral implements neither client-side, so claiming them would make the agent call into nothing.
    public static func initializeParams() -> JSONValue {
        .object([
            "protocolVersion": .number(1),
            "clientCapabilities": .object([
                "elicitation": .object(["form": .object([:])]),
                "session": .object(["compaction": .object([:])]),
                "_meta": .object(["terminal_output": .bool(true)]),
            ]),
            "clientInfo": .object(["name": .string("Admiral")]),
        ])
    }

    public static func newSessionParams(cwd: String, mcpServers: [AcpMCPServer]) -> JSONValue {
        .object(["cwd": .string(cwd), "mcpServers": .array(mcpServers.map(\.json))])
    }

    /// `session/load` and `session/resume` share one shape.
    public static func loadOrResumeParams(
        sessionID: String,
        cwd: String,
        mcpServers: [AcpMCPServer]
    ) -> JSONValue {
        .object([
            "sessionId": .string(sessionID),
            "cwd": .string(cwd),
            "mcpServers": .array(mcpServers.map(\.json)),
        ])
    }

    /// `session/fork` (unstable): the source session's id, plus the new session's cwd and servers.
    public static func forkParams(sessionID: String, cwd: String, mcpServers: [AcpMCPServer]) -> JSONValue {
        loadOrResumeParams(sessionID: sessionID, cwd: cwd, mcpServers: mcpServers)
    }

    /// `session/list` for one folder, from `cursor` (a previous page's `nextCursor`) when given.
    public static func listSessionsParams(cwd: String, cursor: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["cwd": .string(cwd)]
        if let cursor { o["cursor"] = .string(cursor) }
        return .object(o)
    }

    /// `session/cancel` and `session/close`: just the session.
    public static func sessionParams(sessionID: String) -> JSONValue {
        .object(["sessionId": .string(sessionID)])
    }

    public static func setModeParams(sessionID: String, modeID: String) -> JSONValue {
        .object(["sessionId": .string(sessionID), "modeId": .string(modeID)])
    }

    public static func setConfigOptionParams(sessionID: String, configID: String, value: String) -> JSONValue {
        .object(["sessionId": .string(sessionID), "configId": .string(configID), "value": .string(value)])
    }

    public static func promptParams(sessionID: String, text: String) -> JSONValue {
        .object([
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ])
    }

    /// `_session/steering`: same shape as a prompt, plus `_meta.idleBehavior`.
    public static func steeringParams(sessionID: String, text: String) -> JSONValue {
        guard case var .object(o) = promptParams(sessionID: sessionID, text: text) else { return .null }
        o["_meta"] = .object(["idleBehavior": .string("promptRequired")])
        return .object(o)
    }
}

public struct AcpMCPServer: Sendable, Equatable {
    public var name: String
    public var url: String
    public var bearer: String

    public init(name: String, url: String, bearer: String) {
        self.name = name
        self.url = url
        self.bearer = bearer
    }

    /// Admiral's session bridge for one tab: `<mcpCallbackURL>/mcp/session` (a trailing `/` on
    /// the callback is dropped), authenticated by the tab's own token.
    public static func sessionBridge(agent: AcpAgentConfig, token: String) -> AcpMCPServer {
        var base = agent.mcpCallbackURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return AcpMCPServer(name: "admiral", url: base + SessionMCPEndpoint.path, bearer: token)
    }

    public var json: JSONValue {
        .object([
            "type": .string("http"),
            "name": .string(name),
            "url": .string(url),
            "headers": .array([
                .object(["name": .string("Authorization"), "value": .string("Bearer \(bearer)")]),
            ]),
        ])
    }
}

public struct AcpCapabilities: Sendable, Hashable {
    public var agentName: String?
    public var agentVersion: String?
    public var loadSession = false
    public var resume = false
    public var fork = false
    public var list = false
    public var close = false
    public var mcpHTTP = false
    public var steering = false

    public init(initializeResult r: JSONValue) {
        let caps = r["agentCapabilities"]
        agentName = r["agentInfo"]?["name"]?.stringValue
        agentVersion = r["agentInfo"]?["version"]?.stringValue
        loadSession = caps?["loadSession"]?.boolValue ?? r["loadSession"]?.boolValue ?? false
        // Presence of the key means supported; accept it under agentCapabilities or at the top level.
        let sessionCaps = caps?["sessionCapabilities"] ?? r["sessionCapabilities"]
        func has(_ key: String) -> Bool {
            guard let v = sessionCaps?[key] else { return false }
            if case .null = v { return false }
            if case .bool(false) = v { return false }
            return true
        }
        fork = has("fork")
        list = has("list")
        resume = has("resume")
        close = has("close")
        mcpHTTP = (caps?["mcpCapabilities"] ?? r["mcpCapabilities"])?["http"]?.boolValue ?? false
        steering = caps?["_meta"]?["steering"]?["supported"]?.boolValue
            ?? r["_meta"]?["steering"]?["supported"]?.boolValue
            ?? false
    }
}

public enum AcpStopReason: String, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}
