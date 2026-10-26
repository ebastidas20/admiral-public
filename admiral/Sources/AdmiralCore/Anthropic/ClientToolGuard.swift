import Foundation

/// Keeps an API tool tab on the `client` MCP server. Built-ins are also stripped at
/// launch (`--tools ""`); this hook is the backstop for anything that flag misses,
/// including Admiral's own bridge tools, which must not run locally during a parked turn.
public enum ClientToolGuard {
    /// `permissions.deny` entries written into an API tool tab's `--settings` file.
    /// The hook denies by prefix, so this list is only the built-ins Claude would
    /// otherwise run before a hook is consulted.
    public static let builtInDenyList = [
        "Bash", "Edit", "Read", "Write", "Glob", "Grep", "WebFetch", "WebSearch",
        "Task", "TaskOutput", "TaskStop", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet",
        "NotebookEdit", "TodoWrite", "AskUserQuestion", "Skill", "SlashCommand",
        "EnterPlanMode", "ExitPlanMode", "ToolSearch", "LSP",
        "ListMcpResources", "ReadMcpResource", "Agent", "SendMessage",
    ]

    public static let denyReason =
        "This API tab only runs the user's client tools (mcp__client__*). "
        + "Built-in tools and other MCP servers are denied. Call the client tool instead."

    /// Deny JSON when `name` is not a `client` tool on an API tool tab; nil when the
    /// tab is a normal session or the call is allowed through to the MCP park.
    public static func preToolUse(payload: Data, base: URL, token: String) -> String? {
        guard ClientToolCatalog.isEnabled(base: base, token: token) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let name = obj["tool_name"] as? String else { return nil }
        if name.hasPrefix(ClientToolNames.mcpPrefix) { return nil }
        if ClientToolCatalog.contains(name, base: base, token: token) { return nil }
        return denyJSON
    }

    public static var denyJSON: String {
        let object: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": denyReason,
        ]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
