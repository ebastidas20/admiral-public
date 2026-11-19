import Foundation

/// Polls the pull requests of the repos a session has written to, and tells the session when
/// one of them moves. Driven from the app tick, like the watchdog and the goals nudge.
///
/// **It only runs where a watchdog is watching.** `isWatched` is the whole cost control: a
/// session under an armed watchdog is one being driven to done, and its PR is the thing most
/// worth knowing about; every other tab is left alone rather than turned into a GitHub poller.
///
/// Fetching is injected (`Fetcher`) so the rules are testable offline — the app passes a
/// closure backed by `GitHubService`, which owns the shared `gh` rate limit.
@MainActor
public final class PRWatchService: ObservableObject {
    /// `session` is the tab the repo belongs to — so the app asks gh where that tab's files are.
    public typealias Fetcher = @Sendable (_ session: AgentSession, _ root: String, _ branches: [String]) async
        -> [PRStatus]

    /// How often a repo is polled, and the slower cadence for one whose PRs have all merged
    /// (nothing left to learn, but a new branch may still show up).
    public static let interval: TimeInterval = 60
    public static let settledInterval: TimeInterval = 10 * 60

    private let manager: SessionManager
    private let store: PRWatchStore
    private let idle: IdleClock
    private let isWatched: (String) -> Bool
    private let fetch: Fetcher

    /// Last poll and in-flight guard, keyed `<sid>|<root>`.
    private var lastFetch: [String: Date] = [:]
    private var inFlight: Set<String> = []
    /// Results that landed since the last tick, by session then repo root. Consumed (and
    /// cleared) by the next tick — the machine only ever sees repos actually re-polled.
    private var fresh: [String: [String: [PRStatus]]] = [:]
    /// Live fetches, so tests can await them deterministically.
    private var tasks: [Task<Void, Never>] = []

    public init(manager: SessionManager, store: PRWatchStore, idle: IdleClock,
                isWatched: @escaping (String) -> Bool, fetch: @escaping Fetcher) {
        self.manager = manager
        self.store = store
        self.idle = idle
        self.isWatched = isWatched
        self.fetch = fetch
    }

    public func tick(now: Date = Date()) {
        for session in manager.sessions {
            guard let sid = session.claudeSessionID, session.status != .shell else { continue }
            guard isWatched(sid) else { continue }   // the gate
            guard session.canQueryPRs else { continue }   // an ACP tab with no (logged-in) gh
            // The app only keeps the *selected* session's footprint current, and this runs
            // for sessions nobody is looking at — so ask for the repos we are about to poll.
            // Both calls are guarded internally (in-flight / once-only) and read an append
            // log incrementally.
            manager.backfillTouchedRepos(for: session.id)
            manager.refreshTouchedRepos(for: session.id)
            deliver(for: session, sid: sid, now: now)
            poll(session: session, sid: sid, now: now)
        }
    }

    /// Await every in-flight fetch. Tests only — the app never needs to block on this.
    public func drain() async {
        let running = tasks
        tasks = []
        for task in running { await task.value }
    }

    private func deliver(for session: AgentSession, sid: String, now: Date) {
        let landed = fresh.removeValue(forKey: sid).flatMap { $0.isEmpty ? nil : $0 }
        let stored = store.state(forSession: sid)
        // Held news is retried on EVERY tick, against the last poll — not only on the tick a
        // fetch happens to land. The next fetch is 60s away, or 600s once the repo has
        // settled: long enough for a PR to go mergeable and merge with the session never told.
        let digests = landed.map { $0.mapValues { $0.map { PRDigest($0) } } } ?? (stored?.repos ?? [:])
        guard !digests.isEmpty else { return }
        let result = PRWatchMachine.step(.init(
            stored: stored,
            fresh: digests,
            // Told at once, busy or idle — claude takes a mid-turn message, and news that waits
            // for a quiet moment never arrives for a session that is always working. Held only
            // while typing cannot reach claude: a dialog is open (claude's "waiting", which
            // parses to `.unknown`) or claude is not running (`.shell`).
            canType: session.status == .busy || session.status == .idle,
            now: now))
        for effect in result.effects {
            switch effect {
            case let .inject(text):
                manager.deliver(session.id, text: text)
                idle.wake(sid)
            }
        }
        // Only a real poll or an actual injection changes anything worth keeping; a retry tick
        // that stayed silent would otherwise rewrite `checkedAt` to disk every second.
        if landed != nil || !result.effects.isEmpty {
            store.set(result.state, forSession: sid)
        }
        // Keep the panel's chips fresh for unselected sessions too — the same data the
        // Footprint panel fetches for whichever session happens to be on screen.
        for (root, statuses) in landed ?? [:] {
            manager.setTouchedRepoPRs(session.id, root: root, prs: statuses)
        }
    }

    private func poll(session: AgentSession, sid: String, now: Date) {
        let stored = store.state(forSession: sid)
        for repo in session.touchedRepos {
            let branches = repo.branches.filter { !$0.isEmpty }
            guard !branches.isEmpty else { continue }
            let root = repo.root
            let key = "\(sid)|\(root)"
            let due = stored?.isSettled(root: root) == true ? Self.settledInterval : Self.interval
            guard !inFlight.contains(key),
                  now.timeIntervalSince(lastFetch[key] ?? .distantPast) >= due else { continue }
            inFlight.insert(key)
            lastFetch[key] = now
            let fetch = self.fetch
            tasks.append(Task { [weak self] in
                let statuses = await fetch(session, root, branches)
                guard let self else { return }
                self.inFlight.remove(key)
                self.fresh[sid, default: [:]][root] = statuses
            })
        }
    }
}
