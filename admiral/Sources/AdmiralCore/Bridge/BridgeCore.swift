import Foundation

/// A peer station as seen by `roster`. `agentType` is surfaced so callers (and the
/// App Intent entity) can tell it is `claude_code`.
public struct RosterEntry: Sendable, Equatable, Codable {
    public let callsign: String
    public let agentType: String
    public let status: String
    public let cwd: String
    public let branch: String?
}

public struct BridgeResult: Sendable, Equatable {
    public let ok: Bool
    public let message: String
    public static func success(_ message: String) -> BridgeResult { .init(ok: true, message: message) }
    public static func failure(_ message: String) -> BridgeResult { .init(ok: false, message: message) }
}

/// The single engine behind both the MCP server (claude↔claude) and the App Intents
/// (Siri). Resolves sessions in the registry and injects via the `TerminalHost`.
@MainActor
public final class BridgeCore {
    /// Internal so the per-feature extensions (`BridgeCore+Groups`) resolve callers the same way.
    let manager: SessionManager
    private let goalsStore: GoalsStore
    private let prWatchStore: PRWatchStore
    /// Reply obligations, enrolled only by a `needs_reply` hail and closed by `in_reply_to`.
    let inbox = Inbox()
    /// Is a watchdog watching this claude session? Lets `set_structured_output` take a
    /// report the watchdog has not asked for yet. Set by the app, which owns the watchdog.
    public var isWatchdogWatching: (String) -> Bool = { _ in false }
    /// Runs the `schedule_*` tools. Set by the app, which owns the scheduler; nil = none.
    public var scheduler: SchedulerService?
    /// Runs the `group_*` tools. Set by the app only while `features.groups` is on; nil = the
    /// tools do not exist (absent from `tools/list`, refused by `tools/call`).
    public var groups: GroupService?
    /// Whether a `commission` that doesn't say `scratch` makes a scratch tab (Settings →
    /// Bridge & API). Re-read at every call, so a settings edit applies at once.
    public var scratchByDefault: () -> Bool = { false }
    /// Posts a native notification for a session (session id, kind, title, body). Set by the
    /// app to `NotificationService.post`, which applies the Settings toggles — nothing here
    /// checks them, so the gate stays in one place.
    public var postNotification: (UUID, NotificationKind, String, String) -> Void = { _, _, _, _ in }
    private let idGenerator: () -> String

    public init(
        manager: SessionManager,
        goalsStore: GoalsStore? = nil,
        idGenerator: @escaping () -> String = BridgeCore.defaultID
    ) {
        self.manager = manager
        // Defaults to the manager's support dir — the same place the hook helper looks, so
        // a caller that forgets to pass one still lands the goals where they are read.
        self.goalsStore = goalsStore ?? GoalsStore(base: manager.supportDir)
        self.prWatchStore = PRWatchStore(base: manager.supportDir)
        self.idGenerator = idGenerator
    }

    /// Where the per-session files live — the MCP layer reads the goal guidance from here.
    public var supportDir: URL { manager.supportDir }

    nonisolated public static func defaultID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    public func callsign(token: String) -> BridgeResult {
        guard let session = manager.session(forToken: token) else { return .failure("unknown") }
        return .success(session.displayTitle)
    }

    /// The `notify` tool, and the hook helper's route to the app: a native notification for the
    /// caller's own tab (clicking it selects that tab). The title is `@callsign <titleSuffix>`
    /// when a suffix is given, else `title`, else `@callsign`. `kind` is internal (the hooks
    /// pass `question` / `needsInput`); a caller's `notify` is `.agent`.
    public func notify(token: String, kind: String? = nil, title: String? = nil,
                       titleSuffix: String? = nil, body: String) -> BridgeResult {
        guard let session = manager.session(forToken: token) else { return .failure("unknown session") }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure("pass a non-empty `body`") }
        let kind = kind.flatMap(NotificationKind.init(rawValue:)) ?? .agent
        let name = "@\(session.displayTitle)"
        let heading: String
        if let suffix = titleSuffix, !suffix.isEmpty { heading = "\(name) \(suffix)" }
        else if let title, !title.isEmpty { heading = title }
        else { heading = name }
        postNotification(session.id, kind, heading, text)
        return .success("notification requested for \(name)")
    }

    public func roster(token: String) -> [RosterEntry] {
        manager.peers(excludingToken: token)
            .map {
                RosterEntry(
                    callsign: $0.displayTitle, agentType: $0.agentType.id,
                    status: $0.status.rawValue, cwd: $0.cwd, branch: $0.gitBranch
                )
            }
            .sorted { $0.callsign < $1.callsign }
    }

    /// What a hail actually looks like in the receiving terminal: the body, behind the one
    /// thing typed text cannot carry on its own — who sent it.
    ///
    /// Typing arrives as `origin: {kind: "human"}`, so the receiver adds nothing to it: no
    /// envelope, no peer preamble. The cost is that the sender's identity has no metadata to
    /// ride in, and a hail nobody can answer is not worth much — hence the prefix.
    ///
    /// A hail asks for nothing back unless `replyTo` names the message an answer would
    /// close: most hails are a handoff or an FYI, and a standing "reply to me" turns every
    /// one of them into a round trip nobody wanted. When an answer IS wanted, saying so is
    /// what makes it happen — so the ask rides in the text, with the id to quote back.
    /// An ordinary hail says so, too: bare "@SENDER: body" reads like a peer waiting on an
    /// answer, and receivers kept hailing back when nobody wanted it.
    ///
    /// A long body goes as one paste between the typed prefix and marker (`TerminalPrompt`):
    /// typed whole, a 36 KB hail arrived as its last 212 bytes. The ends stay typed, so the
    /// receiver still reads the sender and any reply request as the sender's own words.
    static func prompt(from sender: String, body: String, replyTo msgID: String? = nil) -> TerminalPrompt {
        TerminalPrompt.framing(body, before: "@\(sender): ", after: " " + marker(from: sender, replyTo: msgID))
    }

    /// The hail as the receiver reads it.
    static func wire(from sender: String, body: String, replyTo msgID: String? = nil) -> String {
        prompt(from: sender, body: body, replyTo: msgID).text
    }

    private static func marker(from sender: String, replyTo msgID: String?) -> String {
        guard let msgID else { return noReplyMarker }
        return "[reply requested — answer with hail(to: \"\(sender)\", in_reply_to: \"\(msgID)\")]"
    }

    static let noReplyMarker = "[no reply needed]"

    /// Deliver `body` into a session's claude over its messaging socket — the fallback when
    /// there is no terminal to type into. Returns nil on success, or why it could not.
    ///
    /// This path is louder: the receiver classifies a socket message as a peer and wraps it
    /// in its own envelope and security preamble. Used only when typing is impossible.
    private func deliverOverSocket(_ body: String, to target: AgentSession, from sender: String) -> String? {
        guard let sid = target.claudeSessionID,
              let file = ClaudeSessionFile.all(claudeHome: manager.claudeHome)
                  .first(where: { $0.sessionId == sid && $0.isAddressable })
        else { return "no terminal and no messaging socket for @\(target.displayTitle)" }
        do {
            _ = try ClaudeMessagingSocket.send(body, to: file, from: sender, claudeHome: manager.claudeHome)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// Type first, socket second. Returns nil on success, or why neither worked.
    private func deliver(_ body: String, to target: AgentSession, from sender: String,
                         replyTo msgID: String? = nil) -> String? {
        let prompt = Self.prompt(from: sender, body: body, replyTo: msgID)
        if manager.inject(target.id, prompt: prompt) { return nil }
        return deliverOverSocket(prompt.text, to: target, from: sender)
    }

    /// Why a peer cannot take a typed message. A hail or broadcast is typed into the target's
    /// PTY, so it is only safe where claude's prompt is what reads it: in a bash tab, or a tab
    /// whose claude exited, the text lands in a shell; behind an open dialog, it answers the
    /// dialog. Decided here once for `hail` and `broadcast`; the operator's `inject` is not
    /// gated (only sanitized).
    enum PeerBlock: Equatable {
        case notClaude, claudeExited, dialogOpen

        /// What `hail` says after "not delivered: @x".
        var reason: String {
            switch self {
            case .notClaude:
                return "is not a claude session — typed text would go to its shell; nothing was typed"
            case .claudeExited:
                return "has no claude running (it is back at its shell) — nothing was typed"
            case .dialogOpen:
                return "is waiting on a dialog (a permission prompt or a question) — nothing was "
                    + "typed; try again once it is answered"
            }
        }

        /// What `broadcast` says in parentheses after a skipped station.
        var short: String {
            switch self {
            case .notClaude: return "not a claude session"
            case .claudeExited: return "claude exited"
            case .dialogOpen: return "waiting on a dialog"
            }
        }
    }

    /// Nil when `target` can take a typed message. `.unknown` is not refused: it is also a
    /// fresh tab, and claude's "waiting" is read live from its session file instead.
    func peerBlock(_ target: AgentSession) -> PeerBlock? {
        guard target.agentType.isManaged else { return .notClaude }
        if target.status == .shell { return .claudeExited }
        if let sid = target.claudeSessionID,
           ClaudeSessionFile.newest(sessionId: sid, claudeHome: manager.claudeHome)?.status == "waiting" {
            return .dialogOpen
        }
        return nil
    }

    /// Send `body` to a peer. Nothing is owed back unless `needsReply` says so — delivery is
    /// the whole contract for the ordinary hail, and an unanswered obligation nobody wanted
    /// is just noise in the receiver's queue.
    ///
    /// `needsReply` enrolls one: the receiver is told the id to quote, and `inReplyTo` on the
    /// answer closes it. Enrolment happens only after delivery succeeds, so an unreachable
    /// station leaves no obligation behind.
    public func hail(fromToken: String, to: String, body: String,
                     needsReply: Bool = false, inReplyTo: String? = nil) -> BridgeResult {
        guard let sender = manager.session(forToken: fromToken) else { return .failure("error: unknown sender") }
        guard let target = manager.session(forCallsign: to) else { return .failure("no station @\(to)") }
        if let block = peerBlock(target) {
            return .failure("not delivered: @\(target.displayTitle) \(block.reason)")
        }
        if let inReplyTo { inbox.markAnswered(inReplyTo) }
        let msgID = needsReply ? idGenerator() : nil
        guard let reason = deliver(body, to: target, from: sender.displayTitle, replyTo: msgID) else {
            guard let msgID else { return .success("hailed @\(to)") }
            inbox.enroll(msgID: msgID, from: sender.displayTitle, to: target.displayTitle)
            return .success("hailed @\(to) — reply requested (\(msgID))")
        }
        return .failure("could not reach @\(to): \(reason)")
    }

    public func broadcast(fromToken: String, body: String) -> BridgeResult {
        guard let sender = manager.session(forToken: fromToken) else { return .failure("error: unknown sender") }
        var peers: [AgentSession] = [], skipped: [String] = []
        for peer in manager.peers(excludingToken: fromToken) {
            if let block = peerBlock(peer) { skipped.append("@\(peer.displayTitle) (\(block.short))") }
            else { peers.append(peer) }
        }
        let skipNote = skipped.isEmpty ? ""
            : "; skipped \(skipped.count) that cannot take a typed message: " + skipped.joined(separator: ", ")
        let unreached = peers.filter { deliver(body, to: $0, from: sender.displayTitle) != nil }
        guard unreached.isEmpty else {
            // Naming them matters: "broadcast to 5" while two heard nothing is the failure
            // this whole change was meant to stop being invisible.
            let names = unreached.map { "@\($0.displayTitle)" }.joined(separator: ", ")
            return .success("broadcast to \(peers.count - unreached.count) of "
                + "\(peers.count) station(s) — could not reach \(names)" + skipNote)
        }
        return .success("broadcast to \(peers.count) station(s)" + skipNote)
    }

    /// Rename a station: the caller's own by default, or a peer named by `to`.
    ///
    /// Renames BOTH halves — the tab and the claude inside it — because a name is an
    /// address. `SessionManager.rename` owns the push, so this is only resolution plus
    /// the caller's answer.
    public func renameStation(fromToken token: String, name: String, to: String?) -> BridgeResult {
        let target: AgentSession?
        if let to = to?.trimmingCharacters(in: .whitespaces), !to.isEmpty {
            target = manager.session(forCallsign: to)
        } else {
            target = manager.session(forToken: token)
        }
        guard let target else { return .failure("no station @\(to ?? "self")") }
        let clean = StationName.sanitize(name)
        guard !clean.isEmpty else {
            return .failure("name is empty after sanitizing — nothing to rename to")
        }
        let was = target.displayTitle
        guard clean != was else { return .success("@\(was) is already called that") }
        manager.rename(target.id, to: clean)
        let note = clean == name.trimmingCharacters(in: .whitespacesAndNewlines)
            ? "" : " (sanitized from \"\(name)\")"
        return .success("renamed @\(was) to @\(clean)\(note)")
    }

    /// Inject raw text into a session's terminal by name — NO sender identity required.
    /// Used by the agent-chat relay (a service, not a registered session) to deliver an
    /// inbound chat message verbatim. Unlike `hail`, there is no framing and no inbox
    /// enrollment: the caller supplies the exact text and owns its own attribution. Not gated
    /// by `peerBlock` (the operator may type into any tab), but `TerminalPrompt.injected`
    /// sanitizes it like every other typed message.
    public func inject(to: String, text: String) -> BridgeResult {
        guard let target = manager.session(forCallsign: to) else { return .failure("no station @\(to)") }
        if let refused = refuseIfClientToolsOutstanding(target) { return refused }
        manager.inject(target.id, text: text)
        return .success("injected into @\(target.displayTitle)")
    }

    /// Visible terminal viewport (what the human sees), not the Claude transcript.
    public func readScreen(callsign: String) -> BridgeResult {
        guard let s = manager.session(forCallsign: callsign) else {
            return .failure("no station @\(callsign)")
        }
        guard let text = manager.readScreen(s.id) else {
            return .failure("@\(s.displayTitle): no live terminal")
        }
        return .success("@\(s.displayTitle) screen:\n\(text)")
    }

    /// Operator key chords into a session (`shift+left`, `ctrl+c`, …) — raw PTY bytes, no Enter.
    public func sendKeys(to: String, keys: String) -> BridgeResult {
        guard let target = manager.session(forCallsign: to) else { return .failure("no station @\(to)") }
        if let refused = refuseIfClientToolsOutstanding(target) { return refused }
        let encoded: String
        do { encoded = try TerminalKeyChord.encode(keys) }
        catch { return .failure(String(describing: error)) }
        guard manager.sendKeys(target.id, text: encoded) else {
            return .failure("@\(target.displayTitle): no live terminal")
        }
        return .success("sent keys to @\(target.displayTitle): \(keys)")
    }

    /// A parked client tool call owns the turn. Typing or sending keys would land in
    /// the input box while Claude is blocked inside the `client` MCP server.
    private func refuseIfClientToolsOutstanding(_ target: AgentSession) -> BridgeResult? {
        guard manager.clientToolBroker.hasOutstanding(token: target.token) else { return nil }
        return .failure("@\(target.displayTitle) has a client tool call outstanding; "
            + "refusing until tool_result arrives")
    }

    public func setGoal(fromToken: String, to: String, goals: [String]) -> BridgeResult {
        guard manager.session(forToken: fromToken) != nil else { return .failure("error: unknown sender") }
        guard let target = manager.session(forCallsign: to) else { return .failure("no station @\(to)") }
        return store(goals, on: target)
    }

    /// The `AskUserQuestion` mirror: put the questions in the session's chat, where the card
    /// types the answers back as the next prompt. Returns at once — nothing waits on the user.
    public func askUser(fromToken token: String, questions: [AskQuestion],
                        now: () -> String = PostToolUseHandler.timestamp) -> BridgeResult {
        guard let me = manager.session(forToken: token) else { return .failure("error: unknown caller") }
        guard let sid = me.claudeSessionID else {
            return .failure("@\(me.displayTitle) is not a managed claude session — use the built-in AskUserQuestion")
        }
        guard ChatLedger.mode(base: supportDir, session: sid) == .chat else {
            return .failure("The user is in the terminal, not the chat view: use the built-in "
                + "AskUserQuestion instead.")
        }
        ChatLedger.append(ChatEvent(ts: now(), kind: .ask, questions: questions),
                          base: supportDir, session: sid)
        return .success("Shown to the user in Admiral's chat view. Their answers will arrive as "
            + "their next message. End your turn now with one short line saying you are waiting "
            + "for their answers; do not guess them or continue the task.")
    }

    public func setGoalSelf(fromToken: String, goals: [String]) -> BridgeResult {
        guard let me = manager.session(forToken: fromToken) else { return .failure("error: unknown sender") }
        return store(goals, on: me)
    }

    /// Append goals without restating the list. Never refused: nothing is dropped, so there
    /// is no open goal to account for.
    public func addGoals(fromToken token: String, goals texts: [String]) -> BridgeResult {
        guard let me = manager.session(forToken: token) else { return .failure("error: unknown caller") }
        guard let sid = me.claudeSessionID else {
            return .failure("@\(me.displayTitle) is not a managed claude session — it has no goals")
        }
        let existing = goalsStore.goals(forSession: sid)
        let before = existing?.goals.count ?? 0
        let merged: SessionGoals
        switch SessionGoals.adding(texts, to: existing) {
        case let .success(value): merged = value
        case let .failure(error): return .failure(error.message)
        }
        goalsStore.set(merged, forSession: sid)
        let added = merged.goals.count - before
        guard added > 0 else {
            return .success("already tracking \(texts.count == 1 ? "that goal" : "those goals") "
                + "— nothing added (\(merged.goals.count) total)")
        }
        let (done, total) = merged.progress
        return .success("added \(added) goal\(added == 1 ? "" : "s") (\(done)/\(total) done)")
    }

    /// Mark goals met (or reopen them) without waiting to be probed — what the per-prompt
    /// reminder tells a session to call the moment a goal is actually met. Unknown ids are
    /// reported rather than silently ignored, since the caller typed them.
    public func updateGoals(fromToken token: String, done: [String],
                            open: [String] = [], cancelled: [String] = []) -> BridgeResult {
        guard let me = manager.session(forToken: token) else { return .failure("error: unknown caller") }
        guard let sid = me.claudeSessionID, let goals = goalsStore.goals(forSession: sid) else {
            return .failure("no goals are set on this session")
        }
        let known = Set(goals.goals.map(\.id))
        let unknown = (done + open + cancelled).filter { !known.contains($0) }
        guard unknown.isEmpty else {
            return .failure("unknown goal id(s): \(unknown.joined(separator: ", ")) — this "
                + "session's goals are \(known.sorted().joined(separator: ", "))")
        }
        // Later wins if an id appears twice, so a caller that contradicts itself gets the
        // strongest outcome it named rather than a random one.
        var statuses: [String: GoalStatus] = [:]
        for id in open { statuses[id] = .open }
        for id in cancelled { statuses[id] = .cancelled }
        for id in done { statuses[id] = .met }

        var changed = 0
        goalsStore.update(forSession: sid) { changed = $0.apply(statuses: statuses) }
        let now = goalsStore.goals(forSession: sid)
        let (met, total) = now?.progress ?? (0, 0)
        let verdict = (now?.isComplete ?? false)
            ? "every goal is met"
            : "still open: \(now?.outstanding.map(\.id).joined(separator: ", ") ?? "")"
        return .success("\(changed) goal\(changed == 1 ? "" : "s") updated (\(met)/\(total)) — \(verdict)")
    }

    /// What Admiral last saw of this session's pull requests. Reads the watcher's file rather
    /// than shelling out to `gh`: this path is synchronous (the relay is waiting on it), and a
    /// blocking network call inside a tool call would stall every other session's messages.
    /// The age is part of the answer, so a caller can tell fresh from stale.
    public func prStatus(fromToken token: String, now: Date = Date()) -> BridgeResult {
        guard let me = manager.session(forToken: token) else { return .failure("error: unknown caller") }
        guard let sid = me.claudeSessionID,
              let state = prWatchStore.state(forSession: sid),
              !state.repos.allSatisfy({ $0.value.isEmpty })
        else {
            return .failure("no PR status recorded — the PR watch only runs while this "
                + "session's watchdog is armed")
        }
        var lines: [String] = []
        for root in state.repos.keys.sorted() {
            for digest in state.repos[root] ?? [] {
                lines.append("\((root as NSString).lastPathComponent) #\(digest.number) "
                    + "\(digest.summary) — \(digest.url)")
            }
        }
        let age = state.checkedAt.map { Int(now.timeIntervalSince($0)) } ?? 0
        return .success(lines.joined(separator: "\n") + "\n(checked \(age)s ago)")
    }

    /// Validate and persist — the halves of setting a goal, in one place so `set_goal` and
    /// `set_goal_self` cannot drift apart.
    ///
    /// Nothing is typed into the session. A `/goal` line arms Claude Code's own stop condition,
    /// which Admiral can neither see nor clear, so a goal cleared from the panel would still
    /// hold the session. It hears its goals from Admiral instead: the prompt reminder, the
    /// end-of-turn review, and the idle nudge all read the stored list.
    private func store(_ texts: [String], on target: AgentSession) -> BridgeResult {
        // Goals are for managed Claude tabs only — bash may have a persistent restore id
        // but has no transcript / nudge loop to attach goals to.
        guard let sid = target.claudeSessionID,
              target.agentType.defaultArgs.contains(where: {
                  $0.contains(SessionManager.sessionIDPlaceholder)
              }) else {
            return .failure("@\(target.displayTitle) is not a managed claude session — "
                + "it has no goals")
        }
        // Replacing, not appending — and a replacement may not quietly drop a goal that is
        // still open. That refusal is the whole point: a new directive must not erase an
        // old one nobody decided the fate of.
        let parsed: SessionGoals
        switch SessionGoals.replacing(goalsStore.goals(forSession: sid), with: texts) {
        case let .success(value): parsed = value
        case let .failure(error): return .failure(error.message)
        }

        goalsStore.set(parsed, forSession: sid)
        guard !parsed.isEmpty else { return .success("cleared @\(target.displayTitle)'s goals") }

        let (done, total) = parsed.progress
        return .success("set \(total) goal\(total == 1 ? "" : "s") on "
            + "@\(target.displayTitle) (\(done)/\(total) done)")
    }

    /// Which slot an incoming `set_structured_output` is answering: the caller's `type` when
    /// it named one, otherwise the only armed slot. Deciding this once here is what keeps the
    /// rest of the tool free of "which arm did they mean" branching.
    enum ArmResolution: Equatable {
        case resolved(ArmType)
        case refused(String)
    }

    static func resolveArm(rawType: String?, armed: [ArmType]) -> ArmResolution {
        if let raw = rawType?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            guard let parsed = ArmType(rawValue: raw) else {
                return .refused("unknown type '\(raw)' — expected one of \(ArmType.names)")
            }
            return .resolved(parsed)
        }
        switch armed.count {
        case 0:
            return .refused("no structured output is armed for this session")
        case 1:
            return .resolved(armed[0])
        default:
            return .refused("several structured outputs are armed "
                + "(\(armed.map(\.rawValue).joined(separator: ", "))) — pass `type` to say "
                + "which one you are answering")
        }
    }

    /// Deliver structured output for the calling session: validate against the schema the
    /// named slot carries, store the result on success, and count failed attempts — gives up
    /// (disarms that slot as failed) at `StructuredOutputState.maxAttempts`. The caller's
    /// identity is the session token; `type` is only needed when several slots are armed,
    /// because each slot already knows its own schema and delivery.
    public func setStructuredOutput(fromToken token: String, outputJSON: String,
                                    type rawType: String? = nil) -> BridgeResult {
        guard let me = manager.session(forToken: token) else { return .failure("error: unknown caller") }
        let base = manager.supportDir
        var slots = StructuredOutputStore.readAll(base: base, token: me.token)
        // A report to a watchdog that is watching but has not asked yet — the user says
        // "it's done, close it" between checks. Open its slot now so the answer lands; the
        // watchdog reads it on its next tick. Without this the only way out of an armed
        // watchdog was to wait for its next check.
        let wantsWatchdog = rawType == ArmType.watchdog.rawValue
            || (rawType?.isEmpty != false && slots.armed.isEmpty)
        if wantsWatchdog, slots[.watchdog]?.status != .armed,
           let sid = me.claudeSessionID, isWatchdogWatching(sid),
           let spec = WatchdogMachine.probeSpec {
            manager.armStructuredOutput(tabID: me.id, spec: spec)
            slots = StructuredOutputStore.readAll(base: base, token: me.token)
        }
        let type: ArmType
        switch Self.resolveArm(rawType: rawType, armed: slots.armed) {
        case let .resolved(resolved): type = resolved
        case let .refused(message): return .failure(message)
        }
        guard var state = slots[type], state.status == .armed else {
            return .failure("no \(type.rawValue) structured output is armed for this session")
        }
        let value = outputJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let violations: [String]
        if let value {
            violations = JSONSchemaValidator.validate(value, against: state.schema)
        } else {
            violations = ["output is not valid JSON"]
        }
        guard violations.isEmpty, let value else {
            state.attempts += 1
            let exhausted = state.attempts >= StructuredOutputState.maxAttempts
            state.violations = violations
            if exhausted {
                state.status = .failed
                state.completedAt = Date()
            }
            slots[type] = state
            StructuredOutputStore.writeAll(slots, base: base, token: me.token)
            let verdict = exhausted ? "giving up; respond normally"
                                    : "fix and call set_structured_output again"
            // Restate the schema on a retry — the model has attempts to spend, and the only
            // copy it was given is in the Stop block that armed it. Pointless once exhausted.
            let schema = exhausted ? "" : " — the schema is: " + StopInstruction.schemaText(state.schema)
            return .failure("schema validation failed (attempt \(state.attempts) of "
                + "\(StructuredOutputState.maxAttempts)) — \(verdict): "
                + violations.joined(separator: "; ") + schema)
        }
        state.result = value
        state.status = .fulfilled
        state.completedAt = Date()
        state.violations = nil
        slots[type] = state
        StructuredOutputStore.writeAll(slots, base: base, token: me.token)
        return .success("structured output accepted — end your turn now")
    }

    /// Commission a claude session for the caller. claude is launched plainly — team is a
    /// UI-side label only (set from the promote sheet or the edit popover), never a bridge
    /// concern and never a flag passed to claude.
    ///
    /// `provider` is an optional CC Switch provider id or name (e.g. "GLM5.3 via Fireworks
    /// AI"). Omit it for stock Anthropic. Unknown names fail rather than silently launching
    /// on the wrong model.
    ///
    /// `scratch` makes it a scratch tab (mini sidebar row, not restored, auto-closed once idle
    /// with no open goals); nil follows `scratchByDefault`.
    ///
    /// `outputSchema` (strict JSON Schema, as text) makes every turn of the tab end with
    /// `set_structured_output(type: "output")`; a bad one fails the call before any tab exists.
    public func commission(callsign: String, cwd: String, provider: String? = nil,
                           scratch: Bool? = nil, outputSchema: String? = nil) -> BridgeResult {
        var schema: JSONValue?
        if let text = outputSchema?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            switch Self.parseStrictSchema(text) {
            case let .failure(message): return .failure(message)
            case let .success(parsed): schema = parsed
            }
        }
        let resolvedProvider: CCSwitchProvider?
        switch CCSwitchCatalog.resolve(provider) {
        case let .success(match): resolvedProvider = match
        case let .failure(error): return .failure(error.message)
        }
        let session = manager.commission(callsign: callsign, cwd: cwd,
                                         scratch: scratch ?? scratchByDefault(),
                                         provider: resolvedProvider)
        // Stored before the first prompt can arrive, keyed by the session id it launched with.
        let withOutput = schema != nil && session.claudeSessionID.map {
            OutputSchemaStore.set(schema, base: manager.supportDir, session: $0) == nil
        } == true
        let kind = session.scratch ? "scratch " : ""
        let output = withOutput ? " output_schema=set" : ""
        if let p = resolvedProvider {
            return .success("commissioned \(kind)@\(session.displayTitle) provider=\(p.name)\(output) "
                + "(session=\(session.id.uuidString.prefix(8)))")
        }
        return .success("commissioned \(kind)@\(session.displayTitle)\(output) "
            + "(session=\(session.id.uuidString.prefix(8)))")
    }

    /// Plain interactive login zsh — same recipe as the app's "New Bash" (no transcript /
    /// hooks; still restorable via OpenSessionsStore).
    private static let bashAgentType = AgentType(
        id: "bash", displayName: "Bash", executableName: "zsh",
        defaultArgs: ["-il"], symbolName: "terminal"
    )

    // MARK: - Operator fleet tools (no station sender required)

    /// Every session Admiral is hosting — richer than peer `roster`, which is from one
    /// station's point of view.
    public func listSessions() -> BridgeResult {
        let sessions = manager.sessions
        guard !sessions.isEmpty else { return .success("(no sessions)") }
        let lines = sessions.map { s -> String in
            let branch = s.gitBranch.map { " branch=\($0)" } ?? ""
            let provider = s.providerName.map { " provider=\($0)" }
                ?? s.providerID.map { " provider_id=\($0)" } ?? ""
            return "@\(s.displayTitle) [\(s.agentType.id)] \(s.status.rawValue) cwd=\(s.cwd)\(branch)\(provider)"
        }
        return .success(lines.joined(separator: "\n"))
    }

    public func sessionStatus(callsign: String) -> BridgeResult {
        guard let s = manager.session(forCallsign: callsign) else {
            return .failure("no station @\(callsign)")
        }
        var parts = ["@\(s.displayTitle) is \(s.status.rawValue)",
                     "type=\(s.agentType.id)", "cwd=\(s.cwd)"]
        if let name = s.providerName {
            parts.append("provider=\(name)")
        } else if let id = s.providerID {
            parts.append("provider_id=\(id)")
        } else {
            parts.append("provider=stock")
        }
        if let branch = s.gitBranch { parts.append("branch=\(branch)") }
        if let at = s.lastActivityAt {
            parts.append("last_activity=\(Int(Date().timeIntervalSince(at)))s_ago")
        }
        let convo = manager.conversations[s.id]
        if let plan = convo?.plan, !plan.items.isEmpty {
            let p = plan.progress
            var planLine = "plan \(p.done)/\(p.total)"
            if let current = plan.items.first(where: { $0.state == .inProgress }) {
                planLine += " — \(current.title)"
            }
            parts.append(planLine)
        }
        let isManagedClaude = s.agentType.defaultArgs.contains(where: {
            $0.contains(SessionManager.sessionIDPlaceholder)
        })
        if isManagedClaude, let sid = s.claudeSessionID,
           let goals = goalsStore.goals(forSession: sid), !goals.isEmpty {
            let open = goals.outstanding.map(\.id)
            let (done, total) = goals.progress
            if open.isEmpty {
                parts.append("goals: all met (\(done)/\(total))")
            } else {
                parts.append("goals open: \(open.joined(separator: ", ")) (\(done)/\(total))")
            }
        } else if !isManagedClaude {
            parts.append("goals: n/a (not a managed claude session)")
        } else {
            parts.append("goals: none")
        }
        if isManagedClaude, let sid = s.claudeSessionID,
           OutputSchemaStore.schema(base: manager.supportDir, session: sid) != nil {
            parts.append(Self.outputLine(
                StructuredOutputStore.read(base: manager.supportDir, token: s.token, type: .output)))
        }
        return .success(parts.joined(separator: "\n"))
    }

    /// `session_status`'s line for a tab with an output schema: the latest round's outcome.
    static func outputLine(_ state: StructuredOutputState?) -> String {
        guard let state, let round = state.round else { return "output_schema=set (no turn yet)" }
        switch state.status {
        case .armed: return "output_schema=set round \(round): owed"
        case .failed: return "output_schema=set round \(round): failed"
        case .fulfilled:
            let json = state.result.map { StopInstruction.schemaText($0) } ?? "null"
            return "output_schema=set round \(round): \(json)"
        }
    }

    /// Set, replace or (empty `schemaJSON`) clear a tab's output schema. A schema that is not
    /// strict JSON Schema is refused with every reason; clearing also disarms the slot.
    public func setOutputSchema(callsign: String, schemaJSON: String) -> BridgeResult {
        guard let s = manager.session(forCallsign: callsign) else { return .failure("no station @\(callsign)") }
        guard let sid = s.claudeSessionID, s.agentType.defaultArgs.contains(where: {
            $0.contains(SessionManager.sessionIDPlaceholder)
        }) else { return .failure("@\(s.displayTitle) is not a claude session — it has no turns to hold") }
        let trimmed = schemaJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            OutputSchemaStore.set(nil, base: manager.supportDir, session: sid)
            StructuredOutputStore.clear(base: manager.supportDir, token: s.token, type: .output)
            return .success("cleared the output schema of @\(s.displayTitle)")
        }
        switch Self.parseStrictSchema(trimmed) {
        case let .failure(message): return .failure(message)
        case let .success(schema):
            if let problems = OutputSchemaStore.set(schema, base: manager.supportDir, session: sid) {
                return .failure("output schema refused: " + problems.joined(separator: "; "))
            }
            return .success("@\(s.displayTitle) now owes this output every turn, from its next prompt")
        }
    }

    enum SchemaParse { case success(JSONValue), failure(String) }

    /// The JSON text as a strict schema, or why not — shared by `commission` and
    /// `set_output_schema` so the two cannot accept different things.
    static func parseStrictSchema(_ text: String) -> SchemaParse {
        guard let schema = text.data(using: .utf8)
            .flatMap({ try? JSONDecoder().decode(JSONValue.self, from: $0) }) else {
            return .failure("output schema is not valid JSON")
        }
        let problems = StrictSchema.violations(schema)
        guard problems.isEmpty else {
            return .failure("output schema refused (it must be strict): " + problems.joined(separator: "; "))
        }
        return .success(schema)
    }

    public func focus(callsign: String) -> BridgeResult {
        guard let s = manager.session(forCallsign: callsign) else {
            return .failure("no station @\(callsign)")
        }
        manager.selectedID = s.id
        return .success("focused @\(s.displayTitle)")
    }

    /// Destructive: tears down the session the way the sidebar delete does.
    public func closeSession(callsign: String) -> BridgeResult {
        guard let s = manager.session(forCallsign: callsign) else {
            return .failure("no station @\(callsign)")
        }
        let name = s.displayTitle
        manager.delete(s.id)
        return .success("closed @\(name)")
    }

    /// Last N transcript turns for a session. Caps the *count* of turns (default 20,
    /// hard max 100) — never character-truncates body text, and preserves newlines so
    /// multi-line injects round-trip for the operator.
    public func readRecent(callsign: String, limit: Int = 20) -> BridgeResult {
        guard let s = manager.session(forCallsign: callsign) else {
            return .failure("no station @\(callsign)")
        }
        let n = min(max(limit, 1), 100)
        if manager.conversations[s.id] == nil {
            manager.resolveTranscript(for: s.id)
        }
        guard let convo = manager.conversations[s.id], !convo.turns.isEmpty else {
            return .success("@\(s.displayTitle): (no transcript yet)")
        }
        let turns = Array(convo.turns.suffix(n))
        let blocks = turns.map(Self.formatTurn)
        return .success("@\(s.displayTitle) last \(turns.count) turn(s):\n"
            + blocks.joined(separator: "\n\n"))
    }

    /// Full turn body for the operator — newlines kept, no length cap.
    private static func formatTurn(_ turn: Turn) -> String {
        switch turn {
        case let .user(_, text):
            return "USER:\n\(text)"
        case let .assistant(_, markdown, _):
            return "ASSISTANT:\n\(markdown)"
        case let .thinking(_, text):
            return "THINKING:\n\(text)"
        case let .tool(_, name, params, result, state):
            var out = "TOOL[\(state.rawValue)] \(name)\n\(params)"
            if let result {
                out += "\n→\n\(result)"
            }
            return out
        }
    }

    public func commissionBash(callsign: String, cwd: String, scratch: Bool? = nil) -> BridgeResult {
        let session = manager.commission(
            callsign: callsign, cwd: cwd, agentType: Self.bashAgentType,
            scratch: scratch ?? scratchByDefault())
        let kind = session.scratch ? "scratch " : ""
        return .success("commissioned \(kind)bash @\(session.displayTitle) "
            + "(session=\(session.id.uuidString.prefix(8)))")
    }

    /// PR watch snapshot across every managed claude session that has recorded state.
    public func fleetPrStatus(now: Date = Date()) -> BridgeResult {
        var blocks: [String] = []
        for s in manager.sessions {
            guard let sid = s.claudeSessionID,
                  let state = prWatchStore.state(forSession: sid),
                  !state.repos.allSatisfy({ $0.value.isEmpty })
            else { continue }
            var lines: [String] = ["@\(s.displayTitle):"]
            for root in state.repos.keys.sorted() {
                for digest in state.repos[root] ?? [] {
                    lines.append("  \((root as NSString).lastPathComponent) #\(digest.number) "
                        + "\(digest.summary) — \(digest.url)")
                }
            }
            let age = state.checkedAt.map { Int(now.timeIntervalSince($0)) } ?? 0
            lines.append("  (checked \(age)s ago)")
            blocks.append(lines.joined(separator: "\n"))
        }
        guard !blocks.isEmpty else {
            return .success("no PR status recorded for any session — PR watch only runs while "
                + "a session's watchdog is armed")
        }
        return .success(blocks.joined(separator: "\n\n"))
    }

}
