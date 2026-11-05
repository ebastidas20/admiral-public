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

/// One item of a tool call's `content` (ACP §tool-calls): text, a file diff (`oldText` nil = a
/// new file), or a terminal the agent streams through `_meta.terminal_output`.
public enum AcpToolContent: Hashable, Sendable {
    case text(String)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(id: String)
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
    /// `content`: the text items joined (nil when none); `items`: every content item, in order.
    case toolCallUpdate(
        id: String, status: String?, content: String?, locations: [String], rawInput: JSONValue? = nil,
        items: [AcpToolContent] = [])
    /// A command's output, streamed on a tool call's `_meta.terminal_output` (the terminal id is
    /// the tool call id) — claude-agent-acp's channel for a client advertising
    /// `clientCapabilities._meta.terminal_output`.
    case terminalOutput(toolCallID: String, data: String)
    /// The command ended (`_meta.terminal_exit`); `exitCode` nil when it was signalled.
    case terminalExit(toolCallID: String, exitCode: Int?)
    case plan([AcpPlanEntry])
    case availableCommands([AcpCommandInfo])
    case currentMode(String)
    /// `config_option_update`: the agent's FULL option list.
    case configOptions([AcpConfigOption])
    /// `compaction_update`: `status` in_progress | completed | failed | cancelled; `error` why it failed.
    case compaction(status: String?, error: String?)
    case unknown(String)

    /// The notification's updates: the primary one first, then what rode on its `_meta`
    /// (terminal output, terminal exit). An update that closes its call (`completed` / `failed`)
    /// comes LAST instead, so no consumer ever sees output for a call it has already closed.
    public static func decode(_ params: JSONValue) -> (sessionID: String, updates: [AcpUpdate])? {
        guard let sid = params["sessionId"]?.stringValue, let u = params["update"] else { return nil }
        let primary = decodeUpdate(u)
        let extras = metaUpdates(u["_meta"])
        guard !extras.isEmpty else { return (sid, [primary]) }
        let closes = ["completed", "failed"].contains(u["status"]?.stringValue ?? "")
        return (sid, closes ? extras + [primary] : [primary] + extras)
    }

    private static func metaUpdates(_ meta: JSONValue?) -> [AcpUpdate] {
        guard let meta else { return [] }
        var out: [AcpUpdate] = []
        if let output = meta["terminal_output"], let id = output["terminal_id"]?.stringValue,
           let data = output["data"]?.stringValue, !data.isEmpty {
            out.append(.terminalOutput(toolCallID: id, data: data))
        }
        if let exit = meta["terminal_exit"], let id = exit["terminal_id"]?.stringValue {
            var code: Int?
            if case let .number(n)? = exit["exit_code"] { code = Int(n) }
            out.append(.terminalExit(toolCallID: id, exitCode: code))
        }
        return out
    }

    private static func toolContent(_ item: JSONValue) -> AcpToolContent? {
        switch item["type"]?.stringValue {
        case "diff":
            guard let path = item["path"]?.stringValue else { return nil }
            return .diff(path: path, oldText: item["oldText"]?.stringValue,
                         newText: item["newText"]?.stringValue ?? "")
        case "terminal":
            return item["terminalId"]?.stringValue.map(AcpToolContent.terminal(id:))
        default:
            let t = item["content"]?.asText ?? ""
            return t.isEmpty ? nil : .text(t)
        }
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
            // Items are `{type:"content",content:{type:"text",text}}` or `{type:"diff"|"terminal",…}`.
            let items = (u["content"]?.arrayValue ?? []).compactMap(toolContent)
            let parts = items.compactMap { item -> String? in
                if case let .text(t) = item { return t }
                return nil
            }
            return .toolCallUpdate(
                id: u["toolCallId"]?.stringValue ?? "",
                status: u["status"]?.stringValue,
                content: parts.isEmpty ? nil : parts.joined(separator: "\n"),
                locations: locations,
                rawInput: u["rawInput"],
                items: items)
        case "plan":
            return .plan((u["entries"]?.arrayValue ?? []).map {
                AcpPlanEntry(
                    content: $0["content"]?.stringValue ?? "",
                    status: $0["status"]?.stringValue ?? "pending",
                    priority: $0["priority"]?.stringValue)
            })
        case "available_commands_update":
            return .availableCommands((u["availableCommands"]?.arrayValue ?? []).compactMap {
                guard let name = $0["name"]?.stringValue else { return nil }
                return AcpCommandInfo(
                    name: name.hasPrefix("/") ? String(name.dropFirst()) : name,
                    description: $0["description"]?.stringValue ?? "",
                    hint: $0["input"]?["hint"]?.stringValue)
            })
        case "current_mode_update": return .currentMode(u["currentModeId"]?.stringValue ?? "")
        case "config_option_update": return .configOptions(AcpConfigOption.decodeAll(u))
        case "compaction_update":
            return .compaction(status: u["status"]?.stringValue, error: u["error"]?.stringValue)
        default: return .unknown(kind)
        }
    }
}
