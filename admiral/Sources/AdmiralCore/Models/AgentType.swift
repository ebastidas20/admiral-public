import Foundation

/// The kind of agent CLI a session runs. A value type that carries its own
/// metadata (display name, launch argv, avatar) so adding a new agent later is a
/// new value — not new branches scattered across the UI, intents, and launcher.
public struct AgentType: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    /// The executable name to resolve on PATH (e.g. "claude").
    public let executableName: String
    /// Default arguments appended at launch.
    public let defaultArgs: [String]
    /// SF Symbol used as a fallback avatar when no logo asset is present.
    public let symbolName: String

    public init(
        id: String,
        displayName: String,
        executableName: String,
        defaultArgs: [String],
        symbolName: String
    ) {
        self.id = id
        self.displayName = displayName
        self.executableName = executableName
        self.defaultArgs = defaultArgs
        self.symbolName = symbolName
    }

    /// Claude Code — the only supported agent today. The session-id placeholder is
    /// swapped for a freshly generated id at commission so the transcript path is
    /// deterministic per terminal (see `SessionManager.sessionIDPlaceholder`).
    public static let claudeCode = AgentType(
        id: "claude_code",
        displayName: "Claude Code",
        executableName: "claude",
        defaultArgs: ["--permission-mode", "bypassPermissions", "--session-id", SessionManager.sessionIDPlaceholder],
        symbolName: "sparkles"
    )

    public static let all: [AgentType] = [.claudeCode]

    /// The kind of an ACP agent tab (`SessionManager.commissionACP`). Managed — it has a
    /// transcript (the mirror), hooks and a chat — but never launched from these args: an ACP
    /// tab is started by its agent config, and its `SessionBackend` routes reload and restore.
    public static func acp(agentName: String) -> AgentType {
        AgentType(id: acpID, displayName: agentName, executableName: "",
                  defaultArgs: ["--session-id", SessionManager.sessionIDPlaceholder], symbolName: "shippingbox")
    }

    public static let acpID = "acp"

    /// A managed session carries the `--session-id` placeholder: transcript, injected hooks,
    /// bridge MCP — and so a chat. A bash tab is unmanaged and only ever a terminal.
    public var isManaged: Bool {
        defaultArgs.contains { $0.contains(SessionManager.sessionIDPlaceholder) }
    }
}
