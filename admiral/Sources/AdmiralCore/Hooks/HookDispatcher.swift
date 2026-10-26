import Foundation

/// Routes a hook invocation (`<cli-type> <event>`) to its handler. This switch is the single
/// dispatch site. Returns optional stdout the helper should emit (nil = nothing). An unknown
/// pair is a safe no-op so a misconfigured hook never errors.
///
/// The returned string is written verbatim to stdout, and the helper always exits 0: for
/// Claude Code, blocking *is* that JSON. So "no stdout" means "allow".
///
/// **Admiral does not govern.** Governance lives in `hookd` (a separate repo), registered
/// globally in `~/.claude/settings.json`, so it covers every session rather than only the
/// ones Admiral launched. What remains here are the Admiral features that a hook is the only
/// way to deliver:
///
/// - `PostToolUse` → the touched-repos log (`sessions/<token>/touched.jsonl`)
/// - `Stop` → the structured-output tripwire, which drives the `set_structured_output`
///   bridge MCP tool
/// - `UserPromptSubmit` → the prompt log the session watchdog reads for trigger detection,
///   the open-goals reminder returned as this turn's added context (in full only when it
///   changed), and the re-arm of the tab's `output` slot when it has an output schema
/// - `SessionStart` (clear / compact only) → forgets which goals reminder was sent, since
///   context no longer holds it
///
/// - `UserPromptSubmit` / `Stop` / `Notification` → also the chat ledger the Chat view renders
/// - `PreToolUse` (AskUserQuestion only, except an API tool tab which matches every tool and
///   denies anything that is not `mcp__client__*`) → denies the built-in while the tab shows
///   Chat, so the model uses the bridge mirror the chat can answer; otherwise it posts a
///   native notification
/// - `Notification` (permission / elicitation / idle / agent input) → also a native notification.
///   Claude never emits OSC 9/777 under `TERM_PROGRAM=Admiral`, so the hook is what reaches
///   Notification Center. Delivery is `notifier` (`HookNotifier.send` in the helper, nil = off
///   in tests): bounded, best effort, never changes what claude does.
///
/// Every arm is an Admiral feature, so each needs `ADMIRAL_SESSION`; without it the arm is a
/// no-op. `HookSettings` registers exactly these events. Another one means a new Admiral
/// feature that needs a hook — never a rule.
public enum HookDispatcher {
    @discardableResult
    public static func handle(cliType: String, event: String,
                              payload: Data, base: URL, token: String?,
                              notifier: ((HookNotification, String) -> Void)? = nil) async -> String? {
        guard cliType == "claude" else { return nil }
        // Every remaining arm writes into `sessions/<token>/`, so a missing token is a no-op.
        guard let token, !token.isEmpty else { return nil }

        switch event {
        case "PostToolUse":
            PostToolUseHandler.handle(payload: payload, base: base, token: token)
            return nil

        case "PreToolUse":
            // API tool tabs register this for every tool and deny anything that is not a
            // `client` MCP tool, so the park is the only way a tool runs. Every other tab
            // registers it for AskUserQuestion only.
            if let deny = ClientToolGuard.preToolUse(payload: payload, base: base, token: token) {
                return deny
            }
            // Registered for AskUserQuestion only: denied while the tab shows Chat; in a
            // Terminal tab it is allowed untouched and the user is told claude is asking.
            if let deny = ChatHookHandler.preToolUse(payload: payload, base: base) { return deny }
            if let note = HookNotification.from(event: event, payload: payload) { notifier?(note, token) }
            return nil

        case "Notification":
            ChatHookHandler.notification(payload: payload, base: base)
            if let note = HookNotification.from(event: event, payload: payload) { notifier?(note, token) }
            return nil

        case "UserPromptSubmit":
            ChatHookHandler.prompt(payload: payload, base: base)
            // Capture the prompt for the app-side watchdog (trigger detection).
            WatchdogPromptHandler.handle(payload: payload, base: base, token: token)
            // A new instruction re-arms the end-of-turn goal review.
            GoalReviewLedger.reset(base: base, token: token)
            WatchdogReminder.reset(base: base, token: token)
            // …and a tab with an output schema owes this turn's structured answer.
            if let sessionID = GoalsReminder.sessionID(in: payload) {
                OutputSchemaStore.rearm(base: base, token: token, session: sessionID)
            }
            // An API tool tab is told its client tools instead of the goals reminder —
            // the reminder would send it to `set_goal_self`, which this tab denies.
            if let catalog = ClientToolCatalog.promptContext(base: base, token: token) {
                let parts = [catalog, GroupReminder.context(payload: payload, base: base)].compactMap { $0 }
                return ClientToolCatalog.promptJSON(parts.joined(separator: "\n\n"))
            }
            // …and remind the session of any goal it still owes, visibly, after any group
            // messages it has not seen (nil unless groups are on and it is in one).
            return GoalsReminder.promptJSON(payload: payload, base: base,
                                            prepending: GroupReminder.context(payload: payload, base: base))

        case "SessionStart":
            // Registered for clear|compact only: the earlier goals reminder and group messages
            // left context with them, so the next prompt carries them again.
            GoalsReminder.forgetSent(payload: payload, base: base)
            GroupReminder.rewind(payload: payload, base: base)
            return nil

        case "Stop":
            // Record the reply first: whatever the tripwire or review decides, the agent said it.
            ChatHookHandler.stop(payload: payload, base: base)
            // The structured-output contract outranks the review: a session that owes an
            // answer is already being held, and two blocks in one Stop is one reason too many.
            if let owed = stopTripwire(payload: payload, base: base, token: token) { return owed }
            if let review = goalReview(payload: payload, base: base, token: token) { return review }
            // Last: a watched session is reminded that "done" has to be reported to count.
            return WatchdogReminder.stopJSON(base: base, token: token)

        default:
            return nil
        }
    }

    /// The structured-output tripwire. No armed slot means nil (the turn ends normally).
    ///
    /// A Stop block carries one reason, so the highest-priority armed slot wins this turn and
    /// the rest wait for the next one. Only the winning slot's budget moves: a session
    /// stonewalling its goals nudge must not spend the watchdog's blocks.
    ///
    /// The `output` slot also owes an answer to a run that continues past its fulfilled turn
    /// without a new prompt: the first Stop that finds it fulfilled lets the turn go and marks
    /// it `settled`; a further Stop in the same prompt can only mean the run went on (a
    /// background-task wake-up, a goals-review block), so the slot is re-armed — next round,
    /// fresh budget — and competes for this Stop like any armed slot. A `failed` slot is left
    /// alone: it stays failed until the next prompt re-arms it.
    private static func stopTripwire(payload: Data, base: URL, token: String) -> String? {
        var slots = StructuredOutputStore.readAll(base: base, token: token)
        var dirty = false
        if var out = slots[.output], out.status == .fulfilled {
            if out.settled == true,
               let sessionID = GoalsReminder.sessionID(in: payload),
               let schema = OutputSchemaStore.schema(base: base, session: sessionID) {
                // One write carries the re-arm and (below) its first block, so a reader never
                // sees a fresh armed slot that nothing has blocked yet.
                slots[.output] = StructuredOutputState(schema: schema, delivery: .jsonText,
                                                       round: (out.round ?? 0) + 1)
            } else if out.settled != true {
                out.settled = true
                slots[.output] = out
            }
            dirty = true
        }
        guard let type = slots.armed.first, var state = slots[type] else {
            if dirty { StructuredOutputStore.writeAll(slots, base: base, token: token) }
            return nil
        }
        state.blocks += 1
        guard state.blocks <= StructuredOutputState.maxBlocks else {
            // The session ignored the instruction repeatedly — force-disarm so it
            // cannot loop forever; the endpoint reports the failure.
            state.status = .failed
            state.completedAt = Date()
            if state.violations?.isEmpty != false {
                state.violations = ["no output after \(StructuredOutputState.maxBlocks) blocks"]
            }
            slots[type] = state
            StructuredOutputStore.writeAll(slots, base: base, token: token)
            return nil
        }
        slots[type] = state
        StructuredOutputStore.writeAll(slots, base: base, token: token)
        return StopInstruction.blockJSON(schema: state.schema, type: type)
    }

    /// Ending a turn with goals still open earns one block: say what became of each, or say
    /// what is blocking it. Budgeted per prompt (`GoalReviewLedger`) so it cannot loop.
    private static func goalReview(payload: Data, base: URL, token: String) -> String? {
        guard let sessionID = GoalsReminder.sessionID(in: payload),
              let goals = GoalsStore(base: base).goals(forSession: sessionID),
              !goals.outstanding.isEmpty,
              GoalReviewLedger.consumeBlock(base: base, token: token) else { return nil }
        return GoalsReminder.stopReviewJSON(for: goals)
    }
}
