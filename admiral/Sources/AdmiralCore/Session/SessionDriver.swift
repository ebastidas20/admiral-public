import Foundation

/// What runs a tab's agent: claude in a PTY today, an ACP agent over JSON-RPC later. Chosen
/// once, when the tab is launched, and fixed for its life.
public enum SessionBackend: Hashable, Sendable, Codable {
    case pty
    case acp(agentName: String)
}

/// How input reaches one tab's agent. `SessionManager` holds one per live tab and routes every
/// input funnel through it, so the PTY-or-not question is answered once, at launch, by which
/// driver the tab got — never re-asked at each call site.
///
/// Bookkeeping that is the same for every backend (`ChatLedger.markInjected`, the
/// `lastActivityAt` stamp) stays in `SessionManager`; a driver only moves bytes.
@MainActor
public protocol SessionDriver: AnyObject {
    /// Submit a prompt Admiral wrote (`inject`, `send`).
    func submit(prompt: TerminalPrompt) -> Bool
    /// Submit a line as typed (composer, Siri). The text is already in its final form.
    func submitTyped(_ text: String) -> Bool
    /// Admiral's own messages (PR watch, the watchdog) — the path that may arrive mid-turn.
    func deliver(_ text: String) -> Bool
    /// Stop whatever the agent is doing.
    func interrupt()
    /// The chat card's answers to an `AskUserQuestion`.
    func answer(questions: [AskQuestion], answers: [String]) -> Bool
    /// A permission prompt answered "Yes" from the chat.
    func allowPermission() -> Bool
    /// The visible screen, or nil where there is none (ACP).
    func readScreen() -> String?
    /// Raw key-chord bytes; false where there are no keys to send (ACP).
    func sendKeys(_ text: String) -> Bool
    /// End the agent's process.
    func terminate()
    /// The spawned process's pid, when known.
    var pid: Int32? { get }
}

/// A tab whose agent runs in a PTY: every call becomes bytes on its `TerminalHost` handle.
@MainActor
final class PTYSessionDriver: SessionDriver {
    let handle: TerminalHandle
    private let host: TerminalHost
    private let claudeHome: URL
    /// The tab's current record — read at delivery time, since the session id and the
    /// peer-message flag live there, not here.
    private let session: () -> AgentSession?
    /// `SessionManager.sendPeerMessage`, read through so a test's swap still applies.
    private let sendPeerMessage: (_ body: String, _ file: ClaudeSessionFile, _ claudeHome: URL) throws -> Void

    init(
        host: TerminalHost,
        handle: TerminalHandle,
        claudeHome: URL,
        session: @escaping () -> AgentSession?,
        sendPeerMessage: @escaping (_ body: String, _ file: ClaudeSessionFile, _ claudeHome: URL) throws -> Void
    ) {
        self.host = host
        self.handle = handle
        self.claudeHome = claudeHome
        self.session = session
        self.sendPeerMessage = sendPeerMessage
    }

    var pid: Int32? { handle.pid }

    func submit(prompt: TerminalPrompt) -> Bool {
        host.submit(handle, prompt: prompt)
        return true
    }

    func submitTyped(_ text: String) -> Bool {
        host.submit(handle, text: text)
        return true
    }

    /// A tab launched accepting peer messages gets it on claude's messaging socket, so it
    /// never lands in the input box on top of a half-typed prompt and queues while claude
    /// works; any other tab — or a socket that is not there or refuses — is typed into, so
    /// the message is never lost.
    func deliver(_ text: String) -> Bool {
        if let session = session(), session.acceptsPeerMessages,
           let sid = session.claudeSessionID,
           let file = ClaudeSessionFile.all(claudeHome: claudeHome)
               .first(where: { $0.sessionId == sid && $0.isAddressable }),
           (try? sendPeerMessage(text, file, claudeHome)) != nil {
            return true
        }
        return submit(prompt: .injected(text))
    }

    /// Esc, as the terminal's own Esc does.
    func interrupt() { host.sendRaw(handle, text: "\u{1b}") }

    /// The answers go in as the next prompt, typed like the composer's.
    func answer(questions: [AskQuestion], answers: [String]) -> Bool {
        submitTyped(SessionManager.typedText(AskAnswer.text(questions: questions, answers: answers)))
    }

    /// Enter takes claude's pre-selected "Yes".
    func allowPermission() -> Bool {
        host.sendRaw(handle, text: "\r")
        return true
    }

    func readScreen() -> String? { host.captureVisibleText(handle) }

    func sendKeys(_ text: String) -> Bool {
        host.sendRaw(handle, text: text)
        return true
    }

    func terminate() { host.terminate(handle) }
}

extension SessionBackend {
    /// Whether the tab's live state is read from claude's own files — `sessions/<pid>.json` for
    /// status, the `projects/` transcript, the process tree for the pid. The one place that
    /// answers it: an ACP tab's controller pushes its status and its transcript is the mirror,
    /// fixed at launch, so `refreshStatuses` / `resolveTranscript` / `resolveClaudePID` skip it.
    public var readsClaudeFiles: Bool { self == .pty }
}
