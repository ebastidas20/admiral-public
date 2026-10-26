import Foundation

/// What the event stream reads about a session. `SessionManager` conforms; tests use a fake.
@MainActor
public protocol SessionFeedSource: AnyObject {
    /// The tab an address names, as the bridge resolves every address.
    func feedTab(callsign: String) -> (id: UUID, name: String)?
    /// Current status; nil once the tab is gone, which ends the stream.
    func feedStatus(tabID: UUID) -> SessionStatus?
    /// The transcript tail as turns (empty before claude writes its first line).
    func feedTurns(tabID: UUID) async -> [Turn]
    /// The tab's `output` slot as it stands; nil when the tab has no output schema.
    func feedOutput(tabID: UUID) -> StructuredOutputState?
    /// The PHI-redacted copies of output rounds the `admiral` mod has written; nil while
    /// redaction is off for the tab (the raw slot is streamed then).
    func feedRedactedOutput(tabID: UUID) -> [RedactedOutput]?
}

/// `GET /sessions/<callsign>/events` — a live SSE stream of one session's prompts, messages,
/// finished tool calls, status changes and turn stops. No API token is required.
/// The rules for what is sent live in `SessionEventFeed`; this is the socket side:
/// routing, the poll loop and SSE framing.
@MainActor
public final class SessionEventsEndpoint {
    private let source: SessionFeedSource
    private let pollInterval: TimeInterval
    private let pingInterval: TimeInterval

    public init(source: SessionFeedSource,
                pollInterval: TimeInterval = 1.0, pingInterval: TimeInterval = 15) {
        self.source = source
        self.pollInterval = pollInterval
        self.pingInterval = pingInterval
    }

    /// The decoded callsign when `path` is `/sessions/<callsign>/events`, else nil.
    public nonisolated static func callsign(inPath path: String) -> String? {
        let p = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "sessions", parts[2] == "events" else { return nil }
        let name = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        return name.isEmpty ? nil : name
    }

    /// Serve one connection. `write` returns false once the client is gone, which ends the
    /// stream; so does the tab closing. Error responses are written whole and return at once.
    public func handle(_ request: HTTPRequest, write: (Data) -> Bool) async {
        guard !request.looksBrowserOriginated else {
            _ = write(Self.error(403, "cross-origin or non-loopback request refused")); return
        }
        guard let callsign = Self.callsign(inPath: request.path) else {
            _ = write(Self.error(404, "not found: \(request.path)")); return
        }
        guard request.method == "GET" else {
            _ = write(Self.error(405, "use GET /sessions/<callsign>/events")); return
        }
        guard let tab = source.feedTab(callsign: callsign),
              let status = source.feedStatus(tabID: tab.id) else {
            _ = write(Self.error(404, "no session @\(callsign)")); return
        }

        var feed = SessionEventFeed(lastEventID: request.headers["last-event-id"], callsign: tab.name)
        let hello = (try? JSONSerialization.data(
            withJSONObject: ["callsign": tab.name, "status": status.rawValue], options: [.sortedKeys])) ?? Data()
        guard write(HTTPWire.sseHead()), write(HTTPWire.sseFrame(event: "hello", data: hello)) else { return }

        var lastWrite = Date()
        while true {
            // Status before turns: a reply written just after the status flips is still read
            // this poll, rather than one later.
            guard let status = source.feedStatus(tabID: tab.id) else {
                _ = write(HTTPWire.sseFrame(event: "closed", data: Data("{}".utf8)))
                return
            }
            let turns = await source.feedTurns(tabID: tab.id)
            let output = source.feedOutput(tabID: tab.id)
            let redacted = source.feedRedactedOutput(tabID: tab.id)
            for frame in feed.frames(turns: turns, status: status, output: output, redacted: redacted) {
                guard write(Self.frame(frame)) else { return }
                lastWrite = Date()
            }
            if Date().timeIntervalSince(lastWrite) >= pingInterval {
                guard write(Data(": ping\n\n".utf8)) else { return }
                lastWrite = Date()
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    static func frame(_ frame: FeedFrame) -> Data {
        var out = Data()
        if let id = frame.id { out.append(Data("id: \(id)\n".utf8)) }
        out.append(HTTPWire.sseFrame(event: frame.event.name, data: frame.event.data))
        return out
    }

    private static func error(_ status: Int, _ message: String) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return HTTPWire.response(status: status, body: body)
    }
}

extension SessionManager: SessionFeedSource {
    public func feedTab(callsign: String) -> (id: UUID, name: String)? {
        session(forCallsign: callsign).map { ($0.id, $0.displayTitle) }
    }

    /// The cached status the app tick keeps fresh — not a re-read per follower per poll.
    public func feedStatus(tabID: UUID) -> SessionStatus? {
        sessions.first { $0.id == tabID }?.status
    }

    public func feedOutput(tabID: UUID) -> StructuredOutputState? {
        guard let s = sessions.first(where: { $0.id == tabID }) else { return nil }
        return StructuredOutputStore.read(base: supportDir, token: s.token, type: .output)
    }

    /// `output-<round>.json` files that decode, or nil while the tab's redaction flag is off.
    /// The mod's write is not atomic, so a file that does not decode yet is skipped this poll
    /// and sent once it does.
    public func feedRedactedOutput(tabID: UUID) -> [RedactedOutput]? {
        guard let s = sessions.first(where: { $0.id == tabID }),
              FileManager.default.fileExists(
                atPath: AdmiralPaths.redactRepliesFlag(base: supportDir, token: s.token).path)
        else { return nil }
        let dir = AdmiralPaths.redactedOutputDir(base: supportDir, token: s.token)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("output-") && $0.hasSuffix(".json") }
        return names.compactMap { name in
            (try? Data(contentsOf: dir.appendingPathComponent(name)))
                .flatMap { try? JSONDecoder().decode(RedactedOutput.self, from: $0) }
        }
    }

    /// Parsed off the main actor: large transcripts froze the UI when read on it.
    public func feedTurns(tabID: UUID) async -> [Turn] {
        guard let path = transcriptPath(tabID: tabID) else { return [] }
        return await Task.detached(priority: .utility) {
            TranscriptStore.loadTail(path: path).turns
        }.value
    }
}
