import Foundation

/// A tab as the Anthropic endpoint sees it.
public struct AnthropicTab: Sendable {
    public let id: UUID
    public let name: String
    /// Managed = a claude session with a transcript; a plain bash tab is not.
    public let isManaged: Bool
    public init(id: UUID, name: String, isManaged: Bool) {
        self.id = id; self.name = name; self.isManaged = isManaged
    }
}

/// What the Anthropic endpoint needs from the app: resolve a tab by the name the
/// user sees (what a client sends as `ADMIRAL_TAB_NAME`), inject text, and read live
/// status / transcript location. A protocol so endpoint tests run against a scripted
/// fake instead of a real SessionManager.
/// The run itself (inject, live status, transcript, structured-output state) comes from
/// `TabRunBackend`.
@MainActor
public protocol AnthropicBackend: TabRunBackend {
    func tab(named: String) -> AnthropicTab?
    /// Resolve a tab by the claude session id it was launched with (temp or permanent).
    func tab(sessionID: String) -> AnthropicTab?
    /// Create a scratch tab for `sessionID` in `cwd`, resuming its transcript if
    /// one exists on disk. Returns nil if the launch produced no managed session.
    /// `model` is a `ScheduleModel` alias (`haiku`, …) or nil. `clientTools` commissions
    /// an API tool tab (strict MCP, no built-ins, `client` server); nil leaves the tab
    /// interactive.
    func createScratchTab(sessionID: String, cwd: String, model: String?, clientTools: [ClientToolSpec]?) -> AnthropicTab?
    /// `ADMIRAL_SESSION` token for this tab, the key the broker and the MCP process share.
    func sessionToken(tabID: UUID) -> String?
    /// True when this tab was commissioned as an API tool tab.
    func clientToolsEnabled(tabID: UUID) -> Bool
    /// Replace the catalog an API tool tab already serves. No-op unless the tab is one.
    func installClientTools(tabID: UUID, tools: [ClientToolSpec])
    /// The process-wide park table. The broker socket and this endpoint share it.
    var clientToolBroker: ClientToolBroker { get }
    /// Arm the structured-output tripwire for this tab's session (called before inject).
    func armStructuredOutput(tabID: UUID, spec: StructuredOutputSpec)
    /// Release one slot — the endpoint clears its own on every exit path.
    func clearStructuredOutput(tabID: UUID, type: ArmType)
}

extension SessionManager: AnthropicBackend {
    public func tab(named name: String) -> AnthropicTab? {
        guard let s = session(forCallsign: name) else { return nil }
        // A managed session carries the --session-id we launched it with; bash tabs don't.
        return AnthropicTab(id: s.id, name: s.displayTitle, isManaged: s.claudeSessionID != nil)
    }

    public func tab(sessionID: String) -> AnthropicTab? {
        guard let s = sessions.first(where: {
            $0.claudeSessionID?.caseInsensitiveCompare(sessionID) == .orderedSame
        }) else { return nil }
        return AnthropicTab(id: s.id, name: s.displayTitle, isManaged: true)
    }

    public func createScratchTab(sessionID: String, cwd: String, model: String?,
                                 clientTools: [ClientToolSpec]?) -> AnthropicTab? {
        let name = ScratchTabNamer.name(existing: Set(sessions.map(\.displayTitle)))
        let session = commission(
            callsign: name, cwd: cwd, sessionID: sessionID,
            resume: hasTranscript(sessionID: sessionID, cwd: cwd), scratch: true,
            model: model, clientTools: clientTools)
        guard session.claudeSessionID != nil else { return nil }
        // API scratch tabs are visually uniform: the palette gray + the Claude Code sparkles.
        setAppearance(session.id, colorHex: "#8E8E93", symbol: "sparkles")
        return AnthropicTab(id: session.id, name: session.displayTitle, isManaged: true)
    }

    public func sessionToken(tabID: UUID) -> String? {
        sessions.first { $0.id == tabID }?.token
    }

    public func clientToolsEnabled(tabID: UUID) -> Bool {
        guard let token = sessionToken(tabID: tabID) else { return false }
        return ClientToolCatalog.isEnabled(base: supportDir, token: token)
    }

    public func installClientTools(tabID: UUID, tools: [ClientToolSpec]) {
        guard let token = sessionToken(tabID: tabID),
              ClientToolCatalog.isEnabled(base: supportDir, token: token) else { return }
        ClientToolCatalog.write(tools, base: supportDir, token: token)
    }

    @discardableResult
    public func inject(tabID: UUID, text: String) -> InjectOutcome {
        guard let driver = drivers[tabID] else { return .refused }
        guard inject(tabID, text: text) else { return .refused }
        return driver.acceptanceIsDelivery ? .accepted : .typed
    }

    public func liveStatus(tabID: UUID) -> SessionStatus {
        refreshStatuses()
        return sessions.first { $0.id == tabID }?.status ?? .unknown
    }

    public func transcriptPath(tabID: UUID) -> String? {
        guard let s = sessions.first(where: { $0.id == tabID }) else { return nil }
        // Once resolved (the file exists), use that. Otherwise fall back to the
        // deterministic path we launched claude with (`--session-id`), so a brand-new
        // tab whose transcript file doesn't exist yet still has a known location to
        // inject into and then poll — injecting the first message is what creates it.
        if let resolved = s.transcriptPath { return resolved }
        guard let sid = s.claudeSessionID else { return nil }
        return claudeHome.appendingPathComponent("projects")
            .appendingPathComponent(TranscriptLocator.encodeProjectDir(s.cwd))
            .appendingPathComponent("\(sid).jsonl").path
    }

    public func armStructuredOutput(tabID: UUID, spec: StructuredOutputSpec) {
        guard let s = sessions.first(where: { $0.id == tabID }) else { return }
        StructuredOutputStore.write(
            StructuredOutputState(schema: spec.schema, delivery: spec.delivery, toolName: spec.toolName),
            base: supportDir, token: s.token, type: spec.type)
    }

    public func structuredOutputState(tabID: UUID, type: ArmType) -> StructuredOutputState? {
        guard let s = sessions.first(where: { $0.id == tabID }) else { return nil }
        return StructuredOutputStore.read(base: supportDir, token: s.token, type: type)
    }

    public func clearStructuredOutput(tabID: UUID, type: ArmType) {
        guard let s = sessions.first(where: { $0.id == tabID }) else { return }
        StructuredOutputStore.clear(base: supportDir, token: s.token, type: type)
    }
}
