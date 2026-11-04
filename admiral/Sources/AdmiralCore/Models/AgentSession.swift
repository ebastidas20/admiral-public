import Foundation

/// A single agent session Admiral hosts. Pure data (Sendable); the live driver (and its
/// terminal handle) is held separately by `SessionManager`, keyed by `id`.
public struct AgentSession: Identifiable, Sendable, Hashable {
    public let id: UUID
    /// Human name / callsign (defaults from title, editable).
    public var callsign: String
    public var agentType: AgentType
    public var cwd: String
    public var gitBranch: String?
    /// The agent team this session joined at launch (nil = standalone), shown as a tag.
    public var teamName: String?
    /// PID of the spawned `claude` process.
    public var claudePID: Int32?
    /// Persistent session id. For Claude: the `--session-id` (transcript path). For bash:
    /// a restore key only (no transcript). Nil only for odd register()-ed test sessions.
    public var claudeSessionID: String?
    /// When this session's process was spawned. Used to isolate *this* terminal's
    /// transcript — the `.jsonl` created at/after this instant — from other sessions
    /// that share the same workspace dir.
    public var spawnedAt: Date?
    /// Resolved transcript path.
    public var transcriptPath: String?
    public var status: SessionStatus
    /// AI/custom title from the transcript (header text).
    public var title: String?
    /// User-chosen name (rename). Overrides the transcript title and callsign.
    public var customName: String?
    /// User-chosen avatar tint, as a `#RRGGBB` hex string. Nil = theme accent.
    public var avatarColorHex: String?
    /// User-chosen avatar SF Symbol. Nil = the agent type's default symbol.
    public var avatarSymbol: String?
    /// Per-session bridge identity token (`X-Admiral-Session`).
    public let token: String
    /// The CC Switch provider this session was launched on (`CCSwitchProvider.id`), or nil
    /// for stock Anthropic. Set only when the provider's env actually reached the session's
    /// `--settings` file, so the tab never claims a provider it isn't talking to.
    public var providerID: String?
    /// That provider's display name, for the sidebar badge — otherwise a tab on Kimi looks
    /// exactly like a tab on Opus.
    public var providerName: String?
    /// This tab's claude was launched with `crossSessionInbound: "accept"` (Settings →
    /// Sessions), so a message on its messaging socket is delivered instead of held. Fixed at
    /// launch, like the rest of the `--settings` file: flipping the setting changes new tabs
    /// and relaunches, not this one. Decides how `SessionManager.deliver` reaches the tab.
    public var acceptsPeerMessages: Bool = false
    /// What runs this tab's agent, fixed at launch. Decides which `SessionDriver` the
    /// `SessionManager` gives it.
    public var backend: SessionBackend = .pty
    /// The agent's own session id on an ACP tab (`session/new`); nil on a PTY tab.
    public var acpSessionID: String? = nil
    /// Distinct git repos this session has written to, aggregated from its hook log.
    /// Ephemeral (rebuilt from the on-disk log); not part of the initializer.
    public var touchedRepos: [TouchedRepo] = []
    /// Ticket keys found in this session's chat, with status when a connector is signed in.
    /// Ephemeral (rebuilt from the chat ledger by the app); not part of the initializer.
    public var tickets: [TicketRef] = []
    /// The session finished a turn (busy → idle) while you weren't looking at it, and you
    /// haven't visited it since. Drives the sidebar's "unseen completed work" dot. Ephemeral
    /// (in-memory; reset on relaunch); set in `refreshStatuses`, cleared on selection.
    public var hasUnseenWork: Bool = false
    /// Scratch tab (API-created, or asked for on MCP `commission` / the New form): rendered
    /// mini at the bottom of the sidebar, skipped by keyboard navigation and reorder, never
    /// persisted for restore, and reaped once idle with no open goals.
    /// `SessionManager.promote` clears it.
    public var scratch: Bool
    /// Last observed activity — output (the session file's `updatedAt` advancing) or
    /// programmatic input (`send`/`inject`). Ephemeral (in-memory); drives scratch-tab
    /// reaping. Direct user typing isn't observable, but any turn it triggers moves
    /// `updatedAt`, which lands here.
    public var lastActivityAt: Date? = nil
    /// The session file's `updatedAt` at the last status refresh, to detect advancement.
    public var lastFileUpdatedAt: Double? = nil

    public init(
        id: UUID = UUID(),
        callsign: String,
        agentType: AgentType = .claudeCode,
        cwd: String,
        gitBranch: String? = nil,
        teamName: String? = nil,
        claudePID: Int32? = nil,
        claudeSessionID: String? = nil,
        spawnedAt: Date? = nil,
        transcriptPath: String? = nil,
        status: SessionStatus = .unknown,
        title: String? = nil,
        customName: String? = nil,
        avatarColorHex: String? = nil,
        avatarSymbol: String? = nil,
        scratch: Bool = false,
        token: String = UUID().uuidString,
        providerID: String? = nil,
        providerName: String? = nil
    ) {
        self.id = id
        self.callsign = callsign
        self.agentType = agentType
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.teamName = teamName
        self.claudePID = claudePID
        self.claudeSessionID = claudeSessionID
        self.spawnedAt = spawnedAt
        self.transcriptPath = transcriptPath
        self.status = status
        self.title = title
        self.customName = customName
        self.avatarColorHex = avatarColorHex
        self.avatarSymbol = avatarSymbol
        self.scratch = scratch
        self.token = token
        self.providerID = providerID
        self.providerName = providerName
    }

    /// The name shown in the list/header: a user rename, else the callsign it was created
    /// with. claude's AI-generated transcript `title` is deliberately NOT used — the
    /// terminal keeps the name you gave it instead of being renamed on the first prompt.
    public var displayTitle: String {
        if let customName, !customName.isEmpty { return customName }
        // A tab must never render nameless. New tabs get a non-empty callsign at
        // commission; this covers any session persisted before that guard existed.
        return callsign.isEmpty ? "Session" : callsign
    }

    /// The SF Symbol for the avatar: user choice, else the agent type's default.
    public var avatarSymbolName: String { avatarSymbol ?? agentType.symbolName }
}
