import Foundation

/// An Admiral feature an ACP tab may or may not have — decided by what the agent negotiated
/// and by which tools its environment (reached through `exec`) turned out to hold.
public enum AcpFeature: String, CaseIterable, Sendable {
    case branch, touchedRepos, prWatch, fork, importSessions, bridgeTools, steering
}

/// What one ACP tab can do, and why not. The single source the UI (a disabled control and its
/// tooltip) and the git/PR features (skip the tab) both read, so neither re-derives the answer.
///
/// `git`/`gh`/`ghAuthed` are nil until probed — and stay nil when the agent has no exec
/// command, since there is then nowhere to run them. `hasExec` tells those two nils apart, so a
/// tab whose probes are still running says so instead of claiming it has no exec.
public struct AcpCapabilityRecord: Sendable, Hashable {
    public var negotiated: AcpCapabilities
    /// The agent has an exec command — fixed when the record is built, before any probe.
    public var hasExec: Bool
    public var git: Bool?
    public var gh: Bool?
    public var ghAuthed: Bool?

    public init(
        negotiated: AcpCapabilities, hasExec: Bool = false,
        git: Bool? = nil, gh: Bool? = nil, ghAuthed: Bool? = nil
    ) {
        self.negotiated = negotiated
        // A probe result means it ran somewhere: there is an exec.
        self.hasExec = hasExec || git != nil || gh != nil || ghAuthed != nil
        self.git = git
        self.gh = gh
        self.ghAuthed = ghAuthed
    }

    public func isEnabled(_ f: AcpFeature) -> Bool { reason(f) == nil }

    /// Why `f` is off, in the words the UI shows; nil when it is on.
    public func reason(_ f: AcpFeature) -> String? {
        switch f {
        case .branch, .touchedRepos:
            return toolReason(git, tool: "git")
        case .prWatch:
            // PR watch reads the repos the tab wrote to, so whatever stops those stops it first.
            if let blocked = reason(.touchedRepos) { return blocked }
            if let missing = toolReason(gh, tool: "gh") { return missing }
            return ghAuthed == true ? nil : "gh is not logged in in the agent's environment"
        case .fork:
            return negotiated.fork ? nil : Self.unsupported("fork")
        case .importSessions:
            return negotiated.list ? nil : Self.unsupported("session listing")
        case .steering:
            return negotiated.steering ? nil : Self.unsupported("steering")
        case .bridgeTools:
            // Task 10 adds the second cause here: Admiral's session bridge is not running.
            return negotiated.mcpHTTP ? nil : Self.unsupported("HTTP MCP")
        }
    }

    private func toolReason(_ found: Bool?, tool: String) -> String? {
        switch found {
        case nil:
            return hasExec ? "Checking the agent's environment\u{2026}" : "No exec command configured for this agent"
        case false?: return "\(tool) not found in the agent's environment"
        case true?: return nil
        }
    }

    private static func unsupported(_ what: String) -> String { "The agent doesn't support \(what)" }

    /// The bound on each probe: a stopped container must not hold the tab's record back long.
    public static let probeTimeout: TimeInterval = 5

    /// `git --version`, `gh --version`, then `gh auth status` (only when gh is there), each
    /// through `runner` in `cwd`. Exit 0 = present / logged in; a non-zero exit, a launch
    /// failure or a timeout = not. Blocking — call it off the main actor. No runner = all nil.
    public static func probe(runner: CommandRunner?, cwd: String) -> (git: Bool?, gh: Bool?, ghAuthed: Bool?) {
        guard let runner else { return (nil, nil, nil) }
        func succeeds(_ argv: [String]) -> Bool {
            runner.run(argv, cwd: cwd, timeout: probeTimeout)?.code == 0
        }
        let git = succeeds(["git", "--version"])
        let gh = succeeds(["gh", "--version"])
        let ghAuthed = gh && succeeds(["gh", "auth", "status"])
        return (git, gh, ghAuthed)
    }
}

extension AgentSession {
    /// Whether gh may be asked about this tab's PRs: always on a PTY tab (the Mac's gh); on an
    /// ACP tab only once its record says PR watch is on — gh present and logged in where the
    /// agent's files are. The one answer PR watch and the app's PR chips both read.
    public var canQueryPRs: Bool {
        backend == .pty || acpCapabilities?.isEnabled(.prWatch) == true
    }
}
