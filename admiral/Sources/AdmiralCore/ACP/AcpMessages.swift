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

public struct AcpCapabilities: Sendable, Equatable {
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

public struct AcpConfigOption: Sendable, Equatable {
    public var id: String
    public var currentValue: String?
    public var values: [String]

    public init(id: String, currentValue: String?, values: [String]) {
        self.id = id
        self.currentValue = currentValue
        self.values = values
    }

    /// Reads `configOptions` from a `session/new` (or load/resume) result; tolerant of absence.
    public static func decodeAll(_ result: JSONValue) -> [AcpConfigOption] {
        (result["configOptions"]?.arrayValue ?? []).compactMap { o in
            guard let id = o["id"]?.stringValue else { return nil }
            let values = (o["options"]?.arrayValue ?? []).compactMap { $0["value"]?.stringValue }
            return AcpConfigOption(id: id, currentValue: o["currentValue"]?.stringValue, values: values)
        }
    }
}

public enum AcpStopReason: String, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled
}
