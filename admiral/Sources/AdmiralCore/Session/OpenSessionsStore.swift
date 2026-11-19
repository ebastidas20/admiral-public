import Foundation

/// A session worth restoring on next launch. Claude tabs resume via `--resume <sessionID>`;
/// bash tabs reopen a fresh interactive `zsh` in the same folder (same callsign / id).
public struct OpenSessionRecord: Codable, Equatable, Sendable {
    public var cwd: String
    public var sessionID: String
    public var callsign: String
    public var teamName: String?
    /// The CC Switch provider this session was launched on (`CCSwitchProvider.id`), so a
    /// restore resumes it there instead of silently reverting to Anthropic. Absent in
    /// records written before providers existed, which still decode.
    public var providerID: String?
    /// `AgentType.id` (`claude_code`, `bash`, …). Absent in older records → treat as Claude.
    public var agentTypeID: String?
    /// Allowlisted TUI basename to re-run on bash restore (`k9s`). Never carries args.
    /// Absent/nil ⇒ blank zsh. Cleared when nothing allowlisted was running at quit.
    public var restoreCommand: String?
    /// The ACP agent (`AcpAgentConfig.name`) an ACP tab ran on; nil for a PTY tab. Absent in
    /// older records, which still decode.
    public var acpAgentName: String?
    /// That agent's own session id (`session/new`), what a restore resumes or loads. `sessionID`
    /// stays the local id every piece of Admiral state is keyed by.
    public var acpSessionID: String?

    public init(
        cwd: String, sessionID: String, callsign: String, teamName: String? = nil,
        providerID: String? = nil, agentTypeID: String? = nil,
        restoreCommand: String? = nil,
        acpAgentName: String? = nil, acpSessionID: String? = nil
    ) {
        self.cwd = cwd
        self.sessionID = sessionID
        self.callsign = callsign
        self.teamName = teamName
        self.providerID = providerID
        self.agentTypeID = agentTypeID
        self.restoreCommand = restoreCommand
        self.acpAgentName = acpAgentName
        self.acpSessionID = acpSessionID
    }

    /// True when this record should reopen as a plain shell, not Claude Code.
    public var isBash: Bool { agentTypeID == "bash" }
}

/// UserDefaults-backed list of the sessions Admiral has open, so a relaunch can
/// re-open them. Ordered (most-recently-added last). Keyed by sessionID for upsert.
public final class OpenSessionsStore {
    private let defaults: UserDefaults
    private let key = "admiral.openSessions.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func all() -> [OpenSessionRecord] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([OpenSessionRecord].self, from: data)
        else { return [] }
        return list
    }

    public func upsert(_ record: OpenSessionRecord) {
        let existing = all()
        let previous = existing.first { $0.sessionID == record.sessionID }
        var record = record
        // Structural upserts (rename/team/commission) omit restoreCommand — keep the
        // last snapped TUI so a mid-session rename doesn't forget k9s was running.
        if record.restoreCommand == nil {
            record.restoreCommand = previous?.restoreCommand
        }
        var list = existing.filter { $0.sessionID != record.sessionID }
        list.append(record)
        save(list)
    }

    /// Explicitly set or clear the bash TUI reopen command (including nil).
    public func setRestoreCommand(sessionID: String, command: String?) {
        let existing = all()
        guard var record = existing.first(where: { $0.sessionID == sessionID }) else { return }
        record.restoreCommand = command
        var list = existing.filter { $0.sessionID != sessionID }
        list.append(record)
        save(list)
    }

    public func remove(sessionID: String) {
        save(all().filter { $0.sessionID != sessionID })
    }

    /// Reorder the stored records to match `orderedSessionIDs` (drag-to-reorder), keeping
    /// any records not in the list at the end in their existing order.
    public func reorder(_ orderedSessionIDs: [String]) {
        let byID = Dictionary(all().map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        var result = orderedSessionIDs.compactMap { byID[$0] }
        let placed = Set(result.map(\.sessionID))
        result += all().filter { !placed.contains($0.sessionID) }
        save(result)
    }

    private func save(_ list: [OpenSessionRecord]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
            // Flush now so a session created just before an abrupt termination (a hard
            // kill during development, or a crash) is still there to restore next launch.
            defaults.synchronize()
        }
    }
}
