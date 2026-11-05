import Foundation

/// Admiral's hook features for an ACP tab, run in-process. An ACP agent takes no `--settings`
/// file, so nothing would ever run `admiral-hook`; instead the controller calls this at the
/// equivalent moments, and each call builds the payload claude would have sent and hands it to
/// the same `HookDispatcher` arm. Nothing here decides anything an arm decides — it only maps
/// ACP moments onto hook events and reads back the dispatcher's wire JSON.
///
/// | ACP moment | Hook event |
/// |---|---|
/// | a prompt about to go out | `UserPromptSubmit` → `additionalContext` prepended |
/// | `end_turn` | `Stop` → a block's `reason` is the follow-up prompt |
/// | an `edit` tool call completed, with locations | `PostToolUse` (`Edit`, per path) |
/// | `compaction_update` | `SessionStart` `source: "compact"` |
///
/// `session_id` is the tab's local `claudeSessionID` (what goals and the reminder marker key
/// on); `token` is the tab's bridge token (`sessions/<token>/`). PostToolUse needs git where
/// the files are, so it runs only with a `runner` (nil = skipped).
public struct AcpHookAdapter: AcpTurnHooks {
    private let base: URL
    private let token: String
    private let sessionID: String
    private let cwd: String
    private let runner: CommandRunner?
    private let transcriptPath: String?
    private let edits = EditTracker()

    public init(base: URL, token: String, sessionID: String, cwd: String, runner: CommandRunner?,
                transcriptPath: String? = nil) {
        self.base = base
        self.token = token
        self.sessionID = sessionID
        self.cwd = cwd
        self.runner = runner
        self.transcriptPath = transcriptPath
    }

    /// UserPromptSubmit: returns the prompt text to send (additionalContext prepended, separated by "\n\n").
    public func beforePrompt(_ text: String) async -> String {
        let out = await dispatch("UserPromptSubmit", ["prompt": text])
        let specific = Self.object(out)?["hookSpecificOutput"] as? [String: Any]
        guard let context = specific?["additionalContext"] as? String, !context.isEmpty else { return text }
        return context + "\n\n" + text
    }

    /// Stop: returns the follow-up prompt the dispatcher's block asks for, or nil.
    public func afterTurn(lastAssistantMessage: String) async -> String? {
        let out = await dispatch("Stop", ["last_assistant_message": lastAssistantMessage,
                                          "stop_hook_active": false])
        guard let obj = Self.object(out), obj["decision"] as? String == "block",
              let reason = obj["reason"] as? String, !reason.isEmpty else { return nil }
        return reason
    }

    /// An `edit` tool call that completed → PostToolUse `Edit` for each of its paths, once.
    /// The kind, the locations and the status can each arrive on the call or a later update,
    /// in either order (the controller hands each to its own Task), so they are merged by id.
    public func onToolCall(_ update: AcpUpdate) async {
        guard let runner else { return }
        let paths: [String]
        switch update {
        case let .toolCall(id, _, kind, status, _, locations):
            paths = edits.merge(id: id, kind: kind, status: status, locations: locations)
        case let .toolCallUpdate(id, status, _, locations, _, _):
            paths = edits.merge(id: id, kind: nil, status: status, locations: locations)
        default:
            return
        }
        guard !paths.isEmpty else { return }
        let payloads = paths.map { payload("PostToolUse", ["tool_name": "Edit", "tool_input": ["file_path": $0]]) }
        let (base, token) = (base, token)
        // git may be a `docker exec` away: run it off the cooperative pool.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                // The PostToolUse arm itself, with the runner the dispatcher has no slot for.
                for p in payloads { PostToolUseHandler.handle(payload: p, base: base, token: token, runner: runner) }
                done.resume()
            }
        }
    }

    /// Compaction dropped the earlier reminder from context: SessionStart `compact` forgets it.
    public func onCompaction() async {
        _ = await dispatch("SessionStart", ["source": "compact"])
    }

    // MARK: - Payloads

    private func dispatch(_ event: String, _ fields: [String: Any]) async -> String? {
        await HookDispatcher.handle(cliType: "claude", event: event, payload: payload(event, fields),
                                    base: base, token: token)
    }

    private func payload(_ event: String, _ fields: [String: Any]) -> Data {
        var obj: [String: Any] = ["hook_event_name": event, "session_id": sessionID, "cwd": cwd]
        if let transcriptPath { obj["transcript_path"] = transcriptPath }
        obj.merge(fields) { _, new in new }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    private static func object(_ json: String?) -> [String: Any]? {
        json.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
}

/// Per-tool-call state for `onToolCall`: what is known so far, and whether it was recorded.
private final class EditTracker: @unchecked Sendable {
    private struct Call {
        var kind: String?
        var completed = false
        var locations: [String] = []
        var recorded = false
    }
    private let lock = NSLock()
    private var calls: [String: Call] = [:]

    /// Folds an event in; returns the paths to record now (empty unless this event made the
    /// call a completed edit with locations for the first time).
    func merge(id: String, kind: String?, status: String?, locations: [String]) -> [String] {
        lock.withLock {
            var call = calls[id] ?? Call()
            if let kind { call.kind = kind }
            if status == "completed" { call.completed = true }
            for path in locations where !call.locations.contains(path) { call.locations.append(path) }
            defer { calls[id] = call }
            guard !call.recorded, call.completed, call.kind == "edit", !call.locations.isEmpty else { return [] }
            call.recorded = true
            return call.locations
        }
    }
}
