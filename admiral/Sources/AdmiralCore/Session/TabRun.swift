import Foundation

/// What running a prompt in a tab needs: type into it, read its live status, find its
/// transcript, and read a structured-output slot. A protocol so tests drive a scripted fake.
/// What an `inject` can promise. `.typed`: the text went out as keystrokes, which a claude
/// still booting can drop — only the transcript gaining it confirms it. `.accepted`: the tab's
/// driver took it and will send it (an ACP tab's queue); there is nothing to confirm or retry.
/// `.refused`: it went nowhere (no such tab, or a failed or ended one).
public enum InjectOutcome: Sendable, Equatable {
    case typed, accepted, refused
}

@MainActor
public protocol TabRunBackend: AnyObject {
    @discardableResult
    func inject(tabID: UUID, text: String) -> InjectOutcome
    /// Fresh status read (re-reads `sessions/<pid>.json`), never a cached value.
    func liveStatus(tabID: UUID) -> SessionStatus
    /// Current transcript path; nil until claude writes its first line.
    func transcriptPath(tabID: UUID) -> String?
    /// One slot's current state; nil when never armed or already cleared.
    func structuredOutputState(tabID: UUID, type: ArmType) -> StructuredOutputState?
}

/// Types a prompt into a claude tab and waits out the turn: the lifecycle the Anthropic
/// endpoint and scheduled runs share, so there is one tested path.
@MainActor
public struct TabRun {
    public struct Config: Sendable {
        /// If busy is never observed after injecting, complete once output exists
        /// and the tab reads idle after this long (fast turns can slip the 1s poll).
        public var busySeenTimeout: TimeInterval = 10
        /// Hard cap on a turn; return whatever was captured.
        public var turnTimeout: TimeInterval = 600
        public var pollInterval: TimeInterval = 1.0
        /// Keep-alive cadence while no text is flowing.
        public var pingInterval: TimeInterval = 15
        /// Structured output: if the tab reads idle while the slot is still armed with no
        /// Stop block recorded, the Stop hook isn't firing — stop instead of waiting out
        /// `turnTimeout`.
        public var structuredOutputGrace: TimeInterval = 15
        /// How long to wait for a freshly commissioned claude to write its session file
        /// (proof the process booted) before the first inject. A wait, not a gate — on
        /// timeout the inject attempts proceed anyway.
        public var injectReadyTimeout: TimeInterval = 30
        /// Per-attempt window for the transcript to gain the injected user message —
        /// the ground truth that the submit reached claude's TUI.
        public var injectVerifyTimeout: TimeInterval = 10
        /// Inject attempts before giving up.
        public var injectMaxAttempts: Int = 3

        public init(busySeenTimeout: TimeInterval = 10, turnTimeout: TimeInterval = 600,
                    pollInterval: TimeInterval = 1.0, pingInterval: TimeInterval = 15,
                    structuredOutputGrace: TimeInterval = 15, injectReadyTimeout: TimeInterval = 30,
                    injectVerifyTimeout: TimeInterval = 10, injectMaxAttempts: Int = 3) {
            self.busySeenTimeout = busySeenTimeout
            self.turnTimeout = turnTimeout
            self.pollInterval = pollInterval
            self.pingInterval = pingInterval
            self.structuredOutputGrace = structuredOutputGrace
            self.injectReadyTimeout = injectReadyTimeout
            self.injectVerifyTimeout = injectVerifyTimeout
            self.injectMaxAttempts = injectMaxAttempts
        }
    }

    /// What a turn produced, and whether it ended by hitting `turnTimeout` or because the
    /// agent's process went away mid-turn (`.shell`) — the second is a failure, not a timeout.
    public struct Turn: Sendable {
        public var text: String
        public var usage: AnthropicUsage?
        public var timedOut: Bool
        public var agentExited: Bool = false
    }

    let backend: TabRunBackend
    let config: Config

    public init(backend: TabRunBackend, config: Config = Config()) {
        self.backend = backend
        self.config = config
    }

    /// Type `prompt` into the tab and confirm the transcript gained it, re-typing if not.
    ///
    /// A freshly commissioned tab's claude takes seconds to start reading input — keystrokes
    /// typed into the PTY before that are silently lost (the same race the -realCommission
    /// probe works around by re-sending). The session file appears at process boot, so wait
    /// for it (skips the zsh-startup window) first. Returns whether the prompt landed.
    /// A driver that takes input for certain (`.accepted`) is sent to once, never retyped:
    /// on ACP a retry would only queue another copy behind the first.
    @discardableResult
    public func deliver(_ prompt: String, tabID: UUID, path: String, baselineUserCount: Int) async -> Bool {
        let readyDeadline = Date().addingTimeInterval(config.injectReadyTimeout)
        while backend.liveStatus(tabID: tabID) == .unknown, Date() < readyDeadline {
            await sleepPoll()
        }
        for _ in 1...max(config.injectMaxAttempts, 1) {
            if backend.inject(tabID: tabID, text: prompt) == .accepted { return true }
            if await promptLanded(path: path, baselineUserCount: baselineUserCount) { return true }
        }
        return false
    }

    /// Poll the transcript + live status until the turn completes; returns everything
    /// captured. Complete on busy→idle, on the no-busy fallback (output landed and the
    /// tab reads idle after `busySeenTimeout`), or at the hard `turnTimeout` cap. With a
    /// structured-output `slot`, idle counts as done only once that slot resolved.
    ///
    /// `.shell` (the agent's process exited — a PTY claude, or an ACP agent whose connection
    /// closed) ends the turn as a failure (`agentExited`), for every backend: nothing will ever
    /// read idle again. Guarded like idle: only once the turn was seen busy, or once `.shell`
    /// still holds after `busySeenTimeout` — a `.shell` read before the turn was observed does
    /// not end it early. (`.shell` is Admiral's own marker, set on process exit; claude's raw
    /// `"shell"` parses to `.idle`, so a live tab never reads it.)
    public func awaitTurn(
        tabID: UUID, path: String, fromOffset: Int, slot: ArmType? = nil,
        onText: (String) -> Void = { _ in },
        onPing: () -> Void = {}
    ) async -> Turn {
        let started = Date()
        var offset = fromOffset
        var text = ""
        var usage: AnthropicUsage?
        var sawBusy = false
        var lastActivity = Date()
        while true {
            await sleepPoll()
            if let tail = Self.readTail(path: path, fromOffset: offset) {
                let captured = TurnCapture.capture(tail, fromOffset: 0)
                if !captured.text.isEmpty {
                    let chunk = text.isEmpty ? captured.text : "\n\n" + captured.text
                    text += chunk
                    onText(chunk)
                    lastActivity = Date()
                }
                if let u = captured.usage { usage = u }
                offset += captured.newOffset
            }
            if Date().timeIntervalSince(lastActivity) > config.pingInterval {
                onPing()
                lastActivity = Date()
            }
            let status = backend.liveStatus(tabID: tabID)
            if status == .busy { sawBusy = true }
            let elapsed = Date().timeIntervalSince(started)
            // The status file can flap idle at the instant Stop fires, BEFORE the hook's
            // block resumes the turn — so a structured turn additionally requires the
            // slot to be resolved before idle counts as done.
            let soState = slot.flatMap { backend.structuredOutputState(tabID: tabID, type: $0) }
            let soResolved = slot == nil || soState.map { $0.status != .armed } ?? true
            if status == .shell, sawBusy || elapsed > config.busySeenTimeout {
                return Turn(text: text, usage: usage, timedOut: false, agentExited: true)
            }
            if sawBusy, status == .idle, soResolved { break }
            if !sawBusy, elapsed > config.busySeenTimeout, !text.isEmpty, status == .idle, soResolved { break }
            // Grace bail: idle, still armed, and no Stop block ever recorded means the
            // hook isn't firing (broken hook infra) — stop waiting.
            if slot != nil, status == .idle, let s = soState, s.status == .armed, s.blocks == 0,
               elapsed > config.structuredOutputGrace { break }
            if elapsed > config.turnTimeout { return Turn(text: text, usage: usage, timedOut: true) }
        }
        return Turn(text: text, usage: usage, timedOut: false)
    }

    func sleepPoll() async {
        try? await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
    }

    /// Whether the transcript gained a user line beyond `baselineUserCount` within
    /// `injectVerifyTimeout` — the ground truth that a submitted prompt reached claude
    /// (claude writes the user message to the transcript on submit). Counting rather
    /// than exact-matching keeps a garbled retry (doubled text) from looping forever.
    private func promptLanded(path: String, baselineUserCount: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(config.injectVerifyTimeout)
        while Date() < deadline {
            await sleepPoll()
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               TurnCapture.userTexts(in: data).count > baselineUserCount {
                return true
            }
        }
        return false
    }

    /// Read only the bytes appended after `offset`, instead of the whole
    /// transcript, on every poll. A missing file (fresh tab not yet created)
    /// yields nil.
    static func readTail(path: String, fromOffset offset: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return handle.readDataToEndOfFile()
    }
}
