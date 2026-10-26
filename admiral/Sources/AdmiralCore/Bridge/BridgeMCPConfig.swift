import Foundation

/// Builds the per-session `--mcp-config` JSON that registers Admiral's OWN bridge MCP server
/// (the bundled `admiral-bridge-mcp` relay) as `bridge`, so an Admiral-hosted claude reaches
/// this instance's bridge with no dependency on the external bridge package. The relay
/// reads `ADMIRAL_SESSION` / `ADMIRAL_SOCKET` from the environment Admiral already injects, so
/// the config needs only the command. Injected non-strict, so the user's other MCP servers
/// still load alongside it.
public enum BridgeMCPConfig {
    /// The `client` MCP server on an API tool tab. `timeout` is milliseconds.
    public struct ClientServer: Sendable {
        public var command: String
        public var timeoutMs: Int
        public var env: [String: String]
        public init(command: String, timeoutMs: Int, env: [String: String]) {
            self.command = command
            self.timeoutMs = timeoutMs
            self.env = env
        }
    }

    public static func json(command: String) -> [String: Any] {
        json(bridgeCommand: command, client: nil)
    }

    /// `bridge` when Admiral has a bridge relay; `client` when this tab parks the
    /// caller's tools. Interactive tabs pass `client: nil` and stay bridge-only.
    public static func json(bridgeCommand: String?, client: ClientServer?) -> [String: Any] {
        var servers: [String: Any] = [:]
        if let bridgeCommand { servers["bridge"] = ["command": bridgeCommand] }
        if let client {
            var spec: [String: Any] = ["command": client.command, "timeout": client.timeoutMs]
            if !client.env.isEmpty { spec["env"] = client.env }
            servers["client"] = spec
        }
        return ["mcpServers": servers]
    }

    /// Writes the MCP config to `url`. Returns true only if the file was actually written — so
    /// the caller can DECLINE to inject `--mcp-config` on failure rather than point claude at a
    /// missing file (which would refuse to launch). Best-effort: a write failure degrades to
    /// "no bridge," never a broken session.
    @discardableResult
    public static func write(command: String, to url: URL) -> Bool {
        write(bridgeCommand: command, client: nil, to: url)
    }

    @discardableResult
    public static func write(bridgeCommand: String?, client: ClientServer?, to url: URL) -> Bool {
        guard bridgeCommand != nil || client != nil else { return false }
        guard let data = try? JSONSerialization.data(
            withJSONObject: json(bridgeCommand: bridgeCommand, client: client),
            options: .withoutEscapingSlashes
        ) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch { return false }
        return true
    }
}
