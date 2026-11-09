import Foundation

/// Keeps an API tool tab on the `client` MCP server. Built-ins are stripped at
/// launch (`--tools ""`); this hook is the backstop for anything that flag misses,
/// including Admiral's own bridge tools, which must not run locally during a parked turn.
/// Those names are not also written into `permissions.deny`: with the tools absent,
/// Claude Code warns that each deny rule matches no tool.
public enum ClientToolGuard {
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
