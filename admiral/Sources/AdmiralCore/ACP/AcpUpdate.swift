import Foundation

public struct AcpPlanEntry: Sendable, Equatable {
    public var content: String
    public var status: String
    public var priority: String?

    public init(content: String, status: String, priority: String?) {
        self.content = content
        self.status = status
        self.priority = priority
    }
}

/// A decoded `session/update` notification. Decoding is tolerant: missing fields take defaults.
public enum AcpUpdate: Sendable, Equatable {
    case agentMessage(String)
    case agentThought(String)
    case userMessage(String)
    case toolCall(
        id: String, title: String, kind: String?, status: String?, rawInput: JSONValue?, locations: [String])
    /// `rawInput`: the call's input when this update carries it — claude-agent-acp opens every
    /// call with `{}` and sends the real input on its first update.
    case toolCallUpdate(
        id: String, status: String?, content: String?, locations: [String], rawInput: JSONValue? = nil)
    case plan([AcpPlanEntry])
    case availableCommands([String])
    case currentMode(String)
    /// `config_option_update`: the agent's FULL option list.
    case configOptions([AcpConfigOption])
    case compaction
    case unknown(String)

    public static func decode(_ params: JSONValue) -> (sessionID: String, update: AcpUpdate)? {
        guard let sid = params["sessionId"]?.stringValue, let u = params["update"] else { return nil }
        return (sid, decodeUpdate(u))
    }

    private static func decodeUpdate(_ u: JSONValue) -> AcpUpdate {
        let kind = u["sessionUpdate"]?.stringValue ?? ""
        let text = u["content"]?.asText ?? ""
        let locations = (u["locations"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
        switch kind {
        case "agent_message_chunk": return .agentMessage(text)
        case "agent_thought_chunk": return .agentThought(text)
        case "user_message_chunk": return .userMessage(text)
        case "tool_call":
            return .toolCall(
                id: u["toolCallId"]?.stringValue ?? "",
                title: u["title"]?.stringValue ?? "",
                kind: u["kind"]?.stringValue,
                status: u["status"]?.stringValue,
                rawInput: u["rawInput"],
                locations: locations)
        case "tool_call_update":
            // Items are `{type:"content",content:{type:"text",text}}` or `{type:"diff"|"terminal",…}`;
            // only text is flattened.
            let parts = (u["content"]?.arrayValue ?? []).compactMap { item -> String? in
                let t = item["content"]?.asText ?? ""
                return t.isEmpty ? nil : t
            }
            return .toolCallUpdate(
                id: u["toolCallId"]?.stringValue ?? "",
                status: u["status"]?.stringValue,
                content: parts.isEmpty ? nil : parts.joined(separator: "\n"),
                locations: locations,
                rawInput: u["rawInput"])
        case "plan":
            return .plan((u["entries"]?.arrayValue ?? []).map {
                AcpPlanEntry(
                    content: $0["content"]?.stringValue ?? "",
                    status: $0["status"]?.stringValue ?? "pending",
                    priority: $0["priority"]?.stringValue)
            })
        case "available_commands_update":
            return .availableCommands((u["availableCommands"]?.arrayValue ?? []).compactMap {
                $0["name"]?.stringValue
            })
        case "current_mode_update": return .currentMode(u["currentModeId"]?.stringValue ?? "")
        case "config_option_update": return .configOptions(AcpConfigOption.decodeAll(u))
        case "compaction_update": return .compaction
        default: return .unknown(kind)
        }
    }
}
