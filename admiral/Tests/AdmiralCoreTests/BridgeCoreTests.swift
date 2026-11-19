import XCTest
@testable import AdmiralCore

@MainActor
final class BridgeCoreTests: XCTestCase {
    private var goals: GoalsStore!
    private var manager: SessionManager!
    private var goalsBase: URL!

    private func makeBridge() -> (BridgeCore, FakeTerminalHost) {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host,
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/echo"
        )
        manager.register(AgentSession(callsign: "alice", cwd: "/a", claudeSessionID: "sid-a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        manager.register(AgentSession(callsign: "bob", cwd: "/b", claudeSessionID: "sid-b", token: "B"),
                         handle: FakeTerminalHost.Handle(pid: 2))
        self.manager = manager
        goalsBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-goals-\(UUID().uuidString)")
        goals = GoalsStore(base: goalsBase)
        let bridge = BridgeCore(manager: manager, goalsStore: goals,
                                idGenerator: { "id123" })
        return (bridge, host)
    }

    func testRosterExcludesSelfAndExposesAgentType() {
        let (bridge, _) = makeBridge()
        let roster = bridge.roster(token: "A")
        XCTAssertEqual(roster.map(\.callsign), ["bob"])
        XCTAssertEqual(roster.first?.agentType, "claude_code")
    }

    /// Typed text arrives as `origin: {kind: "human"}`, so the receiver adds no envelope
    /// and no peer preamble — the whole point of typing rather than using the socket. What
    /// goes in is the body behind one prefix, and nothing else.
    func testHailTypesTheBodyBehindTheSenderPrefix() {
        let (bridge, host) = makeBridge()
        let result = bridge.hail(fromToken: "A", to: "bob", body: "hello there")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "hailed @bob")
        XCTAssertTrue(host.combined.contains("@alice: hello there"))
        XCTAssertFalse(host.combined.contains("incoming hail"))
        XCTAssertFalse(host.combined.contains("from:   @alice"))
        XCTAssertFalse(host.combined.contains("msg_id:"))
        XCTAssertFalse(host.combined.contains(String(repeating: "-", count: 40)))
        XCTAssertTrue(host.sent.contains("\r")) // submitted
    }

    /// Typed whole, a long hail lost everything but its tail (see `TerminalPrompt`), so its
    /// body goes as one paste. The prefix and the marker stay typed: the receiver reads who
    /// sent it, and any reply request, as the sender's words rather than as pasted content.
    func testLongHailPastesItsBodyBetweenTheTypedPrefixAndMarker() {
        let (bridge, host) = makeBridge()
        let body = String(repeating: "step\n", count: 400)
        XCTAssertTrue(bridge.hail(fromToken: "A", to: "bob", body: body).ok)
        XCTAssertEqual(host.prompts, [TerminalPrompt(typedBefore: "@alice: ", pasted: body,
                                                     typedAfter: " [no reply needed]")])
    }

    func testLongHailKeepsItsReplyRequestTyped() {
        let (bridge, host) = makeBridge()
        let body = String(repeating: "step\n", count: 400)
        XCTAssertTrue(bridge.hail(fromToken: "A", to: "bob", body: body, needsReply: true).ok)
        XCTAssertEqual(host.prompts.first?.pasted, body)
        XCTAssertEqual(host.prompts.first?.typedAfter,
                       #" [reply requested — answer with hail(to: "alice", in_reply_to: "id123")]"#)
    }

    /// `inject` had no such framing: a 1.2 KB prompt typed in one burst arrived as its last
    /// few bytes. A long one now goes as a paste with the tail typed after it.
    func testLongInjectPastesTheWholeText() {
        let (bridge, host) = makeBridge()
        let text = String(repeating: "x", count: 2048)
        XCTAssertTrue(bridge.inject(to: "bob", text: text).ok)
        XCTAssertEqual(host.prompts, [TerminalPrompt(typedBefore: "", pasted: text,
                                                     typedAfter: TerminalPrompt.injectedTail)])
    }

    func testShortInjectIsTypedWhole() {
        let (bridge, host) = makeBridge()
        XCTAssertTrue(bridge.inject(to: "bob", text: "hello there").ok)
        XCTAssertEqual(host.prompts, [TerminalPrompt(typed: "hello there")])
    }

    /// A short hail is typed exactly as before: one line, nothing pasted.
    func testShortHailIsTypedWhole() {
        let (bridge, host) = makeBridge()
        XCTAssertTrue(bridge.hail(fromToken: "A", to: "bob", body: "hello there").ok)
        XCTAssertEqual(host.prompts, [TerminalPrompt(typed: "@alice: hello there [no reply needed]")])
    }

    // MARK: - Who can take a typed message (PeerBlock)

    private static let bash = AgentType(id: "bash", displayName: "Bash", executableName: "zsh",
                                        defaultArgs: ["-il"], symbolName: "terminal")

    /// A bash tab reads typed text as shell input, so a hail is refused and nothing is typed.
    func testHailRefusesATabThatIsNotAClaudeSession() {
        let (bridge, host) = makeBridge()
        manager.register(AgentSession(callsign: "sh", agentType: Self.bash, cwd: "/s", token: "S"),
                         handle: FakeTerminalHost.Handle(pid: 3))
        let result = bridge.hail(fromToken: "A", to: "sh", body: "inert text")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "not delivered: @sh is not a claude session — typed text "
            + "would go to its shell; nothing was typed")
        XCTAssertTrue(host.sent.isEmpty, host.combined)
    }

    /// A claude tab whose claude exited is a shell again.
    func testHailRefusesAClaudeTabWhoseClaudeExited() {
        let (bridge, host) = makeBridge()
        manager.register(AgentSession(callsign: "gone", cwd: "/g", claudeSessionID: "sid-g",
                                      status: .shell, token: "G"),
                         handle: FakeTerminalHost.Handle(pid: 3))
        let result = bridge.hail(fromToken: "A", to: "gone", body: "inert text")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message,
                       "not delivered: @gone has no claude running (it is back at its shell) — nothing was typed")
        XCTAssertTrue(host.sent.isEmpty, host.combined)
    }

    func testBroadcastSkipsTabsThatCannotTakeATypedMessageAndSaysWhy() {
        let (bridge, host) = makeBridge()
        manager.register(AgentSession(callsign: "sh", agentType: Self.bash, cwd: "/s", token: "S"),
                         handle: FakeTerminalHost.Handle(pid: 3))
        manager.register(AgentSession(callsign: "gone", cwd: "/g", claudeSessionID: "sid-g",
                                      status: .shell, token: "G"),
                         handle: FakeTerminalHost.Handle(pid: 4))
        let result = bridge.broadcast(fromToken: "A", body: "all hands")
        XCTAssertEqual(result.message, "broadcast to 1 station(s); skipped 2 that cannot take a typed "
            + "message: @sh (not a claude session), @gone (claude exited)")
        XCTAssertEqual(host.prompts.count, 1, "only bob is typed to")
    }

    /// A temp claude home holding `sessions/<pid>.json` files for one session id.
    private func claudeHome(_ files: [(pid: Int, status: String, updatedAt: Double)], sid: String) -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-claude-home-\(UUID().uuidString)")
        let dir = home.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let json = #"{"pid":\#(f.pid),"sessionId":"\#(sid)","status":"\#(f.status)","updatedAt":\#(f.updatedAt)}"#
            try? json.write(to: dir.appendingPathComponent("\(f.pid).json"), atomically: true, encoding: .utf8)
        }
        return home
    }

    private func bridgeWithTarget(home: URL) -> (BridgeCore, FakeTerminalHost) {
        let host = FakeTerminalHost()
        let manager = SessionManager(host: host, claudeHome: home, executablePath: "/bin/echo")
        manager.register(AgentSession(callsign: "alice", cwd: "/a", claudeSessionID: "sid-a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        manager.register(AgentSession(callsign: "bob", cwd: "/b", claudeSessionID: "sid-b", token: "B"),
                         handle: FakeTerminalHost.Handle(pid: 2))
        self.manager = manager
        return (BridgeCore(manager: manager, idGenerator: { "id123" }), host)
    }

    /// Typed text behind an open dialog answers the dialog. claude's "waiting" folds into
    /// `.unknown`, so it is read live from the newest session file.
    func testHailRefusesASessionWaitingOnADialog() {
        let home = claudeHome([(10, "idle", 100), (11, "waiting", 200)], sid: "sid-b")
        let (bridge, host) = bridgeWithTarget(home: home)
        let result = bridge.hail(fromToken: "A", to: "bob", body: "inert text")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "not delivered: @bob is waiting on a dialog (a permission prompt "
            + "or a question) — nothing was typed; try again once it is answered")
        XCTAssertTrue(host.sent.isEmpty, host.combined)
    }

    /// A stale "waiting" left by an older pid does not hold a session that has moved on.
    func testHailReadsOnlyTheNewestSessionFile() {
        let home = claudeHome([(10, "waiting", 100), (11, "idle", 200)], sid: "sid-b")
        let (bridge, _) = bridgeWithTarget(home: home)
        XCTAssertTrue(bridge.hail(fromToken: "A", to: "bob", body: "inert text").ok)
    }

    /// `.unknown` is also a fresh tab with no session file yet: it is typed to as before.
    func testHailStillReachesAFreshTabWithNoSessionFile() {
        let (bridge, host) = makeBridge()
        XCTAssertEqual(manager.session(forCallsign: "bob")?.status, .unknown)
        XCTAssertTrue(bridge.hail(fromToken: "A", to: "bob", body: "hi").ok)
        XCTAssertEqual(host.prompts.count, 1)
    }

    /// Escape sequences and control bytes never reach the PTY from a hail.
    func testHailSanitizesItsBody() {
        let (bridge, host) = makeBridge()
        XCTAssertTrue(bridge.hail(fromToken: "A", to: "bob", body: "hi\u{1b}[2J\u{03}there").ok)
        XCTAssertEqual(host.prompts, [TerminalPrompt(typed: "@alice: hi[2Jthere [no reply needed]")])
    }

    /// A newline typed into claude submits early; the body goes as a paste instead.
    func testAShortHailWithANewlineIsPasted() {
        let (bridge, host) = makeBridge()
        XCTAssertTrue(bridge.hail(fromToken: "A", to: "bob", body: "line one\rline two").ok)
        XCTAssertEqual(host.prompts, [TerminalPrompt(typedBefore: "@alice: ", pasted: "line one\nline two",
                                                     typedAfter: " [no reply needed]")])
    }

    /// The operator's inject is not gated (it may type into a bash tab) but is sanitized.
    func testOperatorInjectIsNotGatedButIsSanitized() {
        let (bridge, host) = makeBridge()
        manager.register(AgentSession(callsign: "sh", agentType: Self.bash, cwd: "/s", token: "S"),
                         handle: FakeTerminalHost.Handle(pid: 3))
        XCTAssertTrue(bridge.inject(to: "sh", text: "inert\u{1b}[A\u{15}text").ok)
        XCTAssertEqual(host.prompts, [TerminalPrompt(typed: "inert[Atext")])
    }

    /// The prefix is the only thing identifying the sender — typed text carries no
    /// metadata, so losing it makes every hail anonymous and unanswerable.
    func testWireCarriesTheSender() {
        XCTAssertEqual(BridgeCore.wire(from: "alice", body: "ping"), "@alice: ping [no reply needed]")
    }

    /// The default hail owes nothing back, and says so in the text the receiver reads — a
    /// bare "@alice: …" read as a peer waiting on an answer, and receivers kept hailing back.
    func testHailAsksForNoReplyByDefault() {
        let (bridge, host) = makeBridge()
        XCTAssertTrue(bridge.hail(fromToken: "A", to: "bob", body: "shipped it").ok)
        XCTAssertTrue(host.combined.contains("@alice: shipped it [no reply needed]"), host.combined)
        XCTAssertFalse(host.combined.contains("reply requested"))
        XCTAssertFalse(host.combined.contains("in_reply_to"))
        XCTAssertTrue(bridge.inbox.pending(to: "bob").isEmpty)
    }

    /// `needs_reply` is the whole opt-in: it says so in the text the station reads, and
    /// hands over the id an answer must quote.
    func testNeedsReplyAsksForOneAndEnrollsIt() {
        let (bridge, host) = makeBridge()
        let result = bridge.hail(fromToken: "A", to: "bob", body: "which branch?", needsReply: true)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "hailed @bob — reply requested (id123)")
        XCTAssertTrue(host.combined.contains("@alice: which branch?"), host.combined)
        XCTAssertTrue(host.combined.contains(#"[reply requested — answer with hail(to: "alice", in_reply_to: "id123")]"#),
                      host.combined)
        XCTAssertEqual(bridge.inbox.pending(to: "bob").map(\.msgID), ["id123"])
    }

    /// `submit` types the text and then Enter, so a newline anywhere in the wire would send
    /// half a hail and strand the rest at the prompt.
    func testReplyRequestStaysOnOneLine() {
        let wire = BridgeCore.wire(from: "alice", body: "ping", replyTo: "id123")
        XCTAssertFalse(wire.contains("\n"))
        XCTAssertFalse(wire.contains("\r"))
    }

    /// Answering closes it — the pairing that makes `in_reply_to` mean something.
    func testReplyClosesTheObligation() {
        let (bridge, _) = makeBridge()
        XCTAssertTrue(bridge.hail(fromToken: "A", to: "bob", body: "which branch?", needsReply: true).ok)
        XCTAssertTrue(bridge.hail(fromToken: "B", to: "alice", body: "main", inReplyTo: "id123").ok)
        XCTAssertTrue(bridge.inbox.pending(to: "bob").isEmpty)
    }

    /// An obligation for a hail that never arrived would be chased forever.
    func testUnreachableStationEnrollsNothing() {
        let (bridge, _) = makeBridge()
        manager.register(AgentSession(callsign: "ghost", cwd: "/c", claudeSessionID: "sid-c",
                                      token: "C"), handle: nil)
        XCTAssertFalse(bridge.hail(fromToken: "A", to: "ghost", body: "?", needsReply: true).ok)
        XCTAssertTrue(bridge.inbox.pending(to: "ghost").isEmpty)
    }

    func testHailUnknownStation() {
        let (bridge, _) = makeBridge()
        let result = bridge.hail(fromToken: "A", to: "nobody", body: "x")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "no station @nobody")
    }

    func testBroadcastCountsPeers() {
        let (bridge, host) = makeBridge()
        let result = bridge.broadcast(fromToken: "A", body: "all hands")
        XCTAssertEqual(result.message, "broadcast to 1 station(s)")
        XCTAssertTrue(host.combined.contains("@alice: all hands"))
        XCTAssertFalse(host.combined.contains("incoming broadcast"))
    }

    /// A station with no terminal handle and no socket is UNREACHED. It used to be counted
    /// as delivered — "broadcast to 5" while one heard nothing is the exact failure this
    /// whole path was meant to stop being invisible.
    func testBroadcastNamesTheStationsItCouldNotReach() {
        let (bridge, _) = makeBridge()
        manager.register(AgentSession(callsign: "ghost", cwd: "/c", claudeSessionID: "sid-c",
                                      token: "C"), handle: nil)
        let result = bridge.broadcast(fromToken: "A", body: "all hands")
        XCTAssertTrue(result.message.contains("could not reach @ghost"), result.message)
        XCTAssertTrue(result.message.contains("of 2 station(s)"), result.message)
    }

    /// Same for a one-to-one hail: an unreachable station is a failure, not a success.
    func testHailFailsWhenTheStationCannotBeReached() {
        let (bridge, _) = makeBridge()
        manager.register(AgentSession(callsign: "ghost", cwd: "/c", claudeSessionID: "sid-c",
                                      token: "C"), handle: nil)
        let result = bridge.hail(fromToken: "A", to: "ghost", body: "anyone there")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("could not reach @ghost"), result.message)
    }

    func testRenameStationRenamesTheCallerByDefault() {
        let (bridge, _) = makeBridge()
        let result = bridge.renameStation(fromToken: "A", name: "night shift", to: nil)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, #"renamed @alice to @night-shift (sanitized from "night shift")"#)
        XCTAssertNotNil(bridge.roster(token: "B").first { $0.callsign == "night-shift" })
    }

    func testRenameStationRenamesAPeerByCallsign() {
        let (bridge, _) = makeBridge()
        XCTAssertTrue(bridge.renameStation(fromToken: "A", name: "BOB2", to: "bob").ok)
        XCTAssertEqual(bridge.roster(token: "A").map(\.callsign), ["BOB2"])
    }

    func testRenameStationRefusesANameThatSanitizesAway() {
        let (bridge, _) = makeBridge()
        let result = bridge.renameStation(fromToken: "A", name: "  <>  ", to: nil)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("empty after sanitizing"))
    }

    func testRenameStationUnknownPeer() {
        let (bridge, _) = makeBridge()
        XCTAssertFalse(bridge.renameStation(fromToken: "A", name: "x", to: "nobody").ok)
    }

    func testInjectTypesRawTextByName() {
        let (bridge, host) = makeBridge()
        let result = bridge.inject(to: "bob", text: "raw payload 42")
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.message.contains("@bob"))
        XCTAssertTrue(host.combined.contains("raw payload 42"))
        XCTAssertFalse(host.combined.contains("incoming hail")) // verbatim, no framing
        XCTAssertTrue(host.sent.contains("\r")) // submitted
    }

    func testInjectNeedsNoSenderToken() {
        // The agent-chat relay is not a registered session; inject must work regardless.
        let (bridge, host) = makeBridge()
        let result = bridge.inject(to: "alice", text: "from a tokenless service")
        XCTAssertTrue(result.ok)
        XCTAssertTrue(host.combined.contains("from a tokenless service"))
    }

    func testInjectUnknownStation() {
        let (bridge, _) = makeBridge()
        let result = bridge.inject(to: "nobody", text: "x")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "no station @nobody")
    }

    /// Goals are stored, never typed. A `/goal` line arms Claude Code's own stop condition,
    /// which Admiral can neither see nor clear — so clearing a goal in the panel would leave the
    /// session still held to it. The session hears its goals from Admiral instead: the prompt
    /// reminder, the end-of-turn review, and the idle nudge.
    func testSetGoalSelfTypesNothingIntoTheSession() {
        let (bridge, host) = makeBridge()
        let result = bridge.setGoalSelf(fromToken: "A", goals: ["ship it"])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.map(\.text), ["ship it"])
        XCTAssertEqual(host.sent, [], "no /goal line")
    }

    func testSetGoalOnAPeerTypesNothingIntoIt() {
        let (bridge, host) = makeBridge()
        let result = bridge.setGoal(fromToken: "A", to: "bob", goals: ["clear"])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(goals.goals(forSession: "sid-b")?.goals.map(\.text), ["clear"])
        XCTAssertEqual(host.sent, [], "no /goal line")
    }

    func testSetGoalStoresTheNumberedList() {
        let (bridge, host) = makeBridge()
        let result = bridge.setGoal(fromToken: "A", to: "bob",
                                    goals: ["ship PROJ-510", "no manual pod checks"])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "set 2 goals on @bob (0/2 done)")
        XCTAssertEqual(goals.goals(forSession: "sid-b")?.goals.map(\.text),
                       ["ship PROJ-510", "no manual pod checks"])
        XCTAssertEqual(goals.goals(forSession: "sid-b")?.goals.map(\.id), ["g1", "g2"])
        XCTAssertEqual(host.sent, [], "no /goal line")
    }

    func testSetGoalReplacesOnceTheOldGoalsAreResolved() {
        let (bridge, _) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["old one", "old two"])
        _ = bridge.updateGoals(fromToken: "A", done: ["g1"], open: [], cancelled: ["g2"])
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["only this"])
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.map(\.text), ["only this"])
    }

    /// The point of the rule: a new directive may not erase one nobody decided the fate of.
    func testSetGoalRefusesToDropAnOpenGoal() {
        let (bridge, host) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["ship it", "verify in rnd"])
        let before = host.combined
        let result = bridge.setGoalSelf(fromToken: "A", goals: ["something else"])

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("2 goals are still open"), result.message)
        XCTAssertTrue(result.message.contains("g1) ship it"), result.message)
        // A refusal that only says no gets the caller stuck: it must name every way out,
        // adding first, since "add one more goal" is what usually lands here.
        XCTAssertTrue(result.message.contains("`add_goals`"), result.message)
        XCTAssertTrue(result.message.contains("`update_goals`"), result.message)
        XCTAssertTrue(result.message.contains("`cancelled`"), result.message)
        XCTAssertTrue(result.message.contains("Restating"), result.message)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.map(\.text),
                       ["ship it", "verify in rnd"], "nothing changed")
        XCTAssertEqual(host.combined, before, "and the session was told nothing")
    }

    /// Re-stating a list you have partly finished must not reopen the finished half.
    func testRestatingKeepsWhatWasAlreadyResolved() {
        let (bridge, _) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["ship it", "verify in rnd"])
        _ = bridge.updateGoals(fromToken: "A", done: ["g1"])
        let result = bridge.setGoalSelf(fromToken: "A", goals: ["ship it", "verify in rnd", "and this"])

        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.progress.done, 1)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.outstanding.map(\.text),
                       ["verify in rnd", "and this"])
    }

    /// The refusal this guards against: told to restate its open goals and add one, a session
    /// resent all three with the evidence clause trimmed off each — and exact matching read
    /// that as three deletions. The caller did as it was told and was refused anyway.
    func testRestatingAnOpenGoalParaphrasedIsNotADrop() {
        let (bridge, _) = makeBridge()
        let stored = [
            "A file tagged invoice starts the ImportJob on its own, with no "
                + "manual step and no trigger marker — shown by a child task appearing under a "
                + "real ScanRun",
            "The summary document lands under the same batch_id as the uploaded "
                + "attachment, and reads back with its 40-row shape intact",
        ]
        let paraphrased = [
            "A file tagged invoice starts the ImportJob on its own, with no "
                + "manual step and no trigger marker",
            "The summary document lands under the same batch_id as the uploaded "
                + "attachment and reads back intact",
            "PROJ-711 is Done with the PR and merge SHA posted as a comment",
        ]
        _ = bridge.setGoalSelf(fromToken: "A", goals: stored)
        let result = bridge.setGoalSelf(fromToken: "A", goals: paraphrased)

        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.count, 3)
    }

    /// …but a goal that really is gone still gets refused. The paraphrase fix must not turn
    /// the guard off, and two genuinely different goals must not collapse into one.
    func testShortSimilarGoalsStayDistinctAndADroppedOneIsStillRefused() {
        let (bridge, _) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["ship it"])
        XCTAssertTrue(bridge.setGoalSelf(fromToken: "A", goals: ["ship it", "ship it to prod"]).ok)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.count, 2, "not one merged goal")
        XCTAssertFalse(bridge.setGoalSelf(fromToken: "A", goals: ["something else entirely"]).ok)
    }

    /// Adding needs no restatement at all — the request that started this was "add a goal".
    func testAddGoalsAppendsWithoutTouchingTheOpenOnes() {
        let (bridge, host) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["ship it", "verify in rnd"])
        _ = bridge.updateGoals(fromToken: "A", done: ["g1"])
        let result = bridge.addGoals(fromToken: "A", goals: ["the transcript is saved as an attachment"])

        XCTAssertTrue(result.ok, result.message)
        XCTAssertTrue(result.message.contains("added 1 goal"), result.message)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.map(\.id), ["g1", "g2", "g3"])
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.progress.done, 1, "g1 stays met")
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.last?.text,
                       "the transcript is saved as an attachment")
        XCTAssertEqual(host.sent, [], "no /goal line")
    }

    func testAddGoalsIgnoresOneItIsAlreadyTracking() {
        let (bridge, _) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["ship it to prod and verify"])
        let result = bridge.addGoals(fromToken: "A", goals: ["ship it to prod and verify — checked in rnd"])
        XCTAssertTrue(result.ok, result.message)
        XCTAssertTrue(result.message.contains("nothing added"), result.message)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.count, 1)
    }

    /// A met goal that drops out is not a silent loss — it was already decided.
    func testDroppingAResolvedGoalIsAllowed() {
        let (bridge, _) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["ship it"])
        _ = bridge.updateGoals(fromToken: "A", done: ["g1"])
        XCTAssertTrue(bridge.setGoalSelf(fromToken: "A", goals: ["something new"]).ok)
    }

    func testEmptyListClearsAndSaysSoWithoutInjecting() {
        let (bridge, host) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["something"])
        _ = bridge.updateGoals(fromToken: "A", done: [], cancelled: ["g1"])
        let before = host.combined
        let result = bridge.setGoalSelf(fromToken: "A", goals: [])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.message, "cleared @alice's goals")
        XCTAssertNil(goals.goals(forSession: "sid-a"))
        XCTAssertEqual(host.combined, before, "nothing to tell the session about")
    }

    func testOverlongGoalIsRefusedByNumberAndCount() {
        let (bridge, _) = makeBridge()
        let result = bridge.setGoalSelf(fromToken: "A",
                                        goals: ["fine", String(repeating: "x", count: 281)])
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "goal 2 is 281 characters — keep each goal to 280 or fewer")
        XCTAssertNil(goals.goals(forSession: "sid-a"), "nothing is stored when one goal is bad")
    }

    func testTooManyGoalsRefused() {
        let (bridge, _) = makeBridge()
        let result = bridge.setGoalSelf(fromToken: "A", goals: (1...11).map { "goal \($0)" })
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("too many goals (11)"), result.message)
    }

    // MARK: - update_goals (what the per-prompt reminder tells a session to call)

    func testUpdateGoalsMarksDoneAndReportsWhatIsLeft() {
        let (bridge, _) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["ship it", "verify in rnd"])
        let result = bridge.updateGoals(fromToken: "A", done: ["g1"])
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.message, "1 goal updated (1/2) — still open: g2")
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.progress.done, 1)
    }

    func testUpdateGoalsCanReopenAndSaysWhenEverythingIsMet() {
        let (bridge, _) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["ship it"])
        XCTAssertTrue(bridge.updateGoals(fromToken: "A", done: ["g1"]).message.contains("every goal is met"))
        let reopened = bridge.updateGoals(fromToken: "A", done: [], open: ["g1"])
        XCTAssertTrue(reopened.message.contains("still open: g1"), reopened.message)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.progress.done, 0)
    }

    /// The caller typed these ids, so a typo is reported rather than silently ignored —
    /// unlike the probe answer, where a stale id legitimately means "no longer relevant".
    func testUpdateGoalsRejectsUnknownIds() {
        let (bridge, _) = makeBridge()
        _ = bridge.setGoalSelf(fromToken: "A", goals: ["ship it"])
        let result = bridge.updateGoals(fromToken: "A", done: ["g4"])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("unknown goal id(s): g4"), result.message)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.progress.done, 0)
    }

    func testUpdateGoalsWithoutGoalsSet() {
        let (bridge, _) = makeBridge()
        XCTAssertFalse(bridge.updateGoals(fromToken: "A", done: ["g1"]).ok)
    }

    /// A bash tab is not a managed Claude session — refuse goals rather than silently drop them.
    func testUnmanagedSessionRefusesGoals() {
        let (bridge, _) = makeBridge()
        let bash = AgentType(
            id: "bash", displayName: "Bash", executableName: "zsh",
            defaultArgs: ["-il"], symbolName: "terminal"
        )
        manager.register(
            AgentSession(callsign: "shell", agentType: bash, cwd: "/c",
                         claudeSessionID: "bash-sid", token: "C"),
            handle: FakeTerminalHost.Handle(pid: 3))
        let result = bridge.setGoal(fromToken: "A", to: "shell", goals: ["x"])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("not a managed claude session"), result.message)
    }

    /// The claude-via-function recipe used in production (mirrors `AppModel`): launches
    /// the user's `claude` SHELL FUNCTION plainly — no team flags, just --session-id.
    private func functionRecipe() -> AgentType {
        AgentType(
            id: "claude_code", displayName: "Claude Code", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles"
        )
    }

    /// Regression: the bridge commissions WITHOUT passing an agentType, so the manager
    /// must spawn its CONFIGURED recipe — not the `.claudeCode` static. Before the fix the
    /// bridge fell back to claude's own flags while the executable was `/bin/zsh`, so zsh
    /// got `--permission-mode` as an option ("no such option: permission_mode").
    func testCommissionUsesConfiguredRecipeNotRawClaudeFlags() throws {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/zsh", defaultAgentType: functionRecipe()
        )
        let bridge = BridgeCore(manager: manager)

        XCTAssertTrue(bridge.commission(callsign: "worker", cwd: "/tmp").ok)

        let spawn = try XCTUnwrap(host.spawned.last)
        XCTAssertEqual(spawn.executable, "/bin/zsh")
        XCTAssertEqual(spawn.args.first, "-ilc")
        // claude's flags live INSIDE the -c script (run through the function), never as
        // zsh's own argv. The launch is plain — no team flags reach claude.
        XCTAssertFalse(spawn.args.contains("--permission-mode"))
        XCTAssertTrue(spawn.args.last?.hasPrefix("claude ") == true)
        XCTAssertTrue(spawn.args.last?.contains("--session-id") == true)
        XCTAssertFalse(spawn.args.last?.contains("--team-name") == true)
    }

    /// The bridge has no team surface: a commission by a teamed commissioner carries NO
    /// team label onto the new session (teams are set from the app UI only), and no team
    /// flag ever reaches claude.
    func testBridgeCommissionCarriesNoTeamLabel() {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/zsh", defaultAgentType: functionRecipe()
        )
        manager.register(
            AgentSession(callsign: "boss", cwd: "/b", teamName: "alpha",
                         claudeSessionID: "9580a12b-1111-2222", token: "P"),
            handle: FakeTerminalHost.Handle(pid: 7)
        )
        let bridge = BridgeCore(manager: manager)

        let result = bridge.commission(callsign: "worker", cwd: "/tmp")
        XCTAssertFalse(result.message.contains("team"), result.message)
        XCTAssertNil(manager.sessions.last?.teamName)
        // No team flags reach claude — the launch is plain.
        XCTAssertFalse(host.spawned.last?.args.last?.contains("--team-name") == true)
    }

    /// A rename in Admiral sets `customName` (surfaced as `displayTitle`), not the raw
    /// `callsign` field. The bridge must track that rename — report it from `callsign`,
    /// list it in `roster`, and resolve `hail` by it — exactly as the GUI and App Intents
    /// (which key on `displayTitle`) already do. Regression for "@Test stayed @Test".
    func testBridgeTracksRenameViaDisplayTitle() {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/none"), executablePath: "/bin/echo"
        )
        // "Test" was renamed to "Renamed" in the UI (customName), so displayTitle = "Renamed".
        // Handles matter now: a station with no terminal is unreachable, and this test is
        // about which NAME resolves, not about delivery.
        manager.register(AgentSession(callsign: "Test", cwd: "/a", customName: "Renamed", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        manager.register(AgentSession(callsign: "bob", cwd: "/b", token: "B"),
                         handle: FakeTerminalHost.Handle(pid: 2))
        let bridge = BridgeCore(manager: manager)

        XCTAssertEqual(bridge.callsign(token: "A").message, "Renamed")
        XCTAssertEqual(bridge.roster(token: "B").map(\.callsign), ["Renamed"])
        XCTAssertTrue(bridge.hail(fromToken: "B", to: "Renamed", body: "hi").ok)
        XCTAssertFalse(bridge.hail(fromToken: "B", to: "Test", body: "hi").ok,
                       "the pre-rename raw callsign must no longer resolve")
    }

    /// `read_recent` is turn-count limited only: full bodies, newlines kept, no 240-char chop.
    func testReadRecentPreservesNewlinesAndFullText() {
        let (bridge, _) = makeBridge()
        let long = String(repeating: "A", count: 300) + "\nLINE2\nLINE3"
        let convo = Conversation(turns: [
            .user(id: "1", text: long),
            .assistant(id: "2", markdown: "ok\nsecond", model: nil),
            .user(id: "3", text: "latest"),
        ])
        let alice = manager.session(forCallsign: "alice")!
        manager.setConversation(alice.id, convo)

        let all = bridge.readRecent(callsign: "alice", limit: 20)
        XCTAssertTrue(all.ok, all.message)
        XCTAssertTrue(all.message.contains("USER:\n" + long), all.message)
        XCTAssertTrue(all.message.contains("LINE2\nLINE3"), all.message)
        XCTAssertFalse(all.message.contains("..."), "must not character-truncate")
        XCTAssertTrue(all.message.contains(String(repeating: "A", count: 300)), all.message)

        let limited = bridge.readRecent(callsign: "alice", limit: 1)
        XCTAssertTrue(limited.ok, limited.message)
        XCTAssertTrue(limited.message.contains("last 1 turn(s)"), limited.message)
        XCTAssertTrue(limited.message.contains("USER:\nlatest"), limited.message)
        XCTAssertFalse(limited.message.contains(String(repeating: "A", count: 300)),
                       "limit=1 must drop older turns")
    }

    func testReadScreenReturnsVisibleText() {
        let (bridge, host) = makeBridge()
        host.visibleScreen = "pod-a\npod-b"
        let r = bridge.readScreen(callsign: "alice")
        XCTAssertTrue(r.ok, r.message)
        XCTAssertTrue(r.message.contains("pod-a"), r.message)
        XCTAssertTrue(r.message.contains("pod-b"), r.message)
    }

    func testSendKeysEncodesShiftChordsWithoutEnter() {
        let (bridge, host) = makeBridge()
        let r = bridge.sendKeys(to: "alice", keys: "shift+left,shift+o")
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(host.combined, "\u{1b}[1;2DO")
        XCTAssertFalse(host.sent.contains("\r"), "send_keys must not submit Enter")
    }

    func testSendKeysAcceptsRawAndFunctionKeys() {
        let (bridge, host) = makeBridge()
        let r = bridge.sendKeys(to: "alice", keys: #"raw:\e[1;5A"#)
        XCTAssertTrue(r.ok, r.message)
        XCTAssertEqual(host.combined, "\u{1b}[1;5A")

        let (bridge2, host2) = makeBridge()
        let r2 = bridge2.sendKeys(to: "alice", keys: "shift+f13")
        XCTAssertTrue(r2.ok, r2.message)

        XCTAssertEqual(host2.combined, "\u{1b}[25;2~")
    }

    /// A Claude session id with a transcript under `cwd` relaunches that conversation
    /// (`--resume`). A missing or wrong-cwd id starts a fresh session under the same
    /// id (`--session-id`). An invalid UUID, or an id already open in another tab, fails.
    func testCommissionResumesExistingClaudeSessionOrStartsUnderTheSameId() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let sid = "00000000-0000-4000-8000-000000000abc"
        let cwd = "/Users/me/proj"
        let other = "/Users/me/other"
        func writeTranscript(sessionID: String, cwd: String) throws {
            let dir = home.appendingPathComponent("projects")
                .appendingPathComponent(TranscriptLocator.encodeProjectDir(cwd))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: dir.appendingPathComponent("\(sessionID).jsonl"))
        }
        try writeTranscript(sessionID: sid, cwd: cwd)

        func make() -> (BridgeCore, SessionManager, FakeTerminalHost) {
            let host = FakeTerminalHost()
            let manager = SessionManager(
                host: host, claudeHome: home, executablePath: "/bin/zsh",
                defaultAgentType: functionRecipe()
            )
            return (BridgeCore(manager: manager), manager, host)
        }

        let (bridge, manager, host) = make()
        let before = manager.sessions.count
        let ok = bridge.commission(callsign: "LOAN", cwd: cwd, sessionID: sid)
        XCTAssertTrue(ok.ok, ok.message)
        XCTAssertTrue(ok.message.contains("resumed=true"), ok.message)
        XCTAssertTrue(ok.message.contains("session_id=\(sid)"), ok.message)
        XCTAssertEqual(manager.sessions.count, before + 1)
        XCTAssertEqual(manager.sessions.last?.claudeSessionID, sid)
        let cmd = host.spawned.last?.args.last ?? ""
        XCTAssertTrue(cmd.contains("--resume \(sid)"), "must resume; got: \(cmd)")
        XCTAssertFalse(cmd.contains("--session-id"), "must not also pass --session-id; got: \(cmd)")

        // Uppercase UUID still finds the lowercase file.
        let (bridgeU, managerU, hostU) = make()
        let upper = bridgeU.commission(callsign: "LOAN2", cwd: cwd, sessionID: sid.uppercased())
        XCTAssertTrue(upper.ok, upper.message)
        XCTAssertEqual(managerU.sessions.last?.claudeSessionID, sid)
        XCTAssertTrue((hostU.spawned.last?.args.last ?? "").contains("--resume \(sid)"))

        let (bridgeMiss, managerMiss, hostMiss) = make()
        let missing = "00000000-0000-4000-8000-000000000def"
        let miss = bridgeMiss.commission(callsign: "GONE", cwd: cwd, sessionID: missing)
        XCTAssertTrue(miss.ok, miss.message)
        XCTAssertTrue(miss.message.contains("resumed=false"), miss.message)
        XCTAssertTrue(miss.message.contains("session_id=\(missing)"), miss.message)
        XCTAssertEqual(managerMiss.sessions.count, 1)
        XCTAssertEqual(managerMiss.sessions.last?.claudeSessionID, missing)
        let missCmd = hostMiss.spawned.last?.args.last ?? ""
        XCTAssertTrue(missCmd.contains("--session-id \(missing)"), "missing transcript must start under that id; got: \(missCmd)")
        XCTAssertFalse(missCmd.contains("--resume "), "must not resume a missing transcript; got: \(missCmd)")

        let (bridgeWrong, managerWrong, hostWrong) = make()
        let wrong = bridgeWrong.commission(callsign: "WRONG", cwd: other, sessionID: sid)
        XCTAssertTrue(wrong.ok, wrong.message)
        XCTAssertTrue(wrong.message.contains("resumed=false"), wrong.message)
        XCTAssertEqual(managerWrong.sessions.last?.claudeSessionID, sid)
        let wrongCmd = hostWrong.spawned.last?.args.last ?? ""
        XCTAssertTrue(wrongCmd.contains("--session-id \(sid)"), "wrong cwd has no transcript there; got: \(wrongCmd)")
        XCTAssertFalse(wrongCmd.contains("--resume "), wrongCmd)

        // Same id already open in a tab is refused — don't start a second tab on it.
        let live = bridge.commission(callsign: "COPY", cwd: cwd, sessionID: sid)
        XCTAssertFalse(live.ok, live.message)
        XCTAssertTrue(live.message.contains("already open as @LOAN"), live.message)
        XCTAssertEqual(manager.sessions.count, before + 1)

        let (bridgeBad, managerBad, _) = make()
        let bad = bridgeBad.commission(callsign: "BAD", cwd: cwd, sessionID: "not-a-uuid")
        XCTAssertFalse(bad.ok, bad.message)
        XCTAssertTrue(bad.message.contains("must be a Claude session id"), bad.message)
        XCTAssertEqual(managerBad.sessions.count, 0)

        let (bridgeFresh, managerFresh, hostFresh) = make()
        let fresh = bridgeFresh.commission(callsign: "FRESH", cwd: cwd)
        XCTAssertTrue(fresh.ok, fresh.message)
        XCTAssertTrue(fresh.message.contains("resumed=false"), fresh.message)
        XCTAssertFalse(fresh.message.contains("resumed=true"), fresh.message)
        XCTAssertTrue(fresh.message.contains("session_id="), fresh.message)
        let freshCmd = hostFresh.spawned.last?.args.last ?? ""
        XCTAssertTrue(freshCmd.contains("--session-id"), "fresh launch must use --session-id; got: \(freshCmd)")
        XCTAssertFalse(freshCmd.contains("--resume "), "fresh launch must not resume; got: \(freshCmd)")
        XCTAssertNotEqual(managerFresh.sessions.last?.claudeSessionID, sid)

        let blank = bridgeFresh.commission(callsign: "BLANK", cwd: cwd, sessionID: "   ")
        XCTAssertTrue(blank.ok, blank.message)
        XCTAssertTrue(blank.message.contains("resumed=false"), blank.message)

        let status = bridge.sessionStatus(callsign: "LOAN")
        XCTAssertTrue(status.ok, status.message)
        XCTAssertTrue(status.message.contains("session_id=\(sid)"), status.message)
        let listed = bridge.listSessions()
        XCTAssertTrue(listed.message.contains("session_id=\(sid)"), listed.message)
    }
}
