import XCTest
@testable import AdmiralCore

final class GroupReactionParseTests: XCTestCase {
    func testTheFourEmojisAndLikelyNamesParseAnythingElseDoesNot() {
        XCTAssertEqual(GroupReaction.parse("👀"), .eyes)
        XCTAssertEqual(GroupReaction.parse(" 👍 "), .up)
        XCTAssertEqual(GroupReaction.parse("👎"), .down)
        XCTAssertEqual(GroupReaction.parse("✅"), .done)
        XCTAssertEqual(GroupReaction.parse("👍🏽"), .up, "a skin tone is the same reaction")
        XCTAssertEqual(GroupReaction.parse("✅\u{FE0F}"), .done)
        XCTAssertEqual(GroupReaction.parse(":eyes:"), .eyes)
        XCTAssertEqual(GroupReaction.parse("thumbsup"), .up)
        XCTAssertEqual(GroupReaction.parse("-1"), .down)
        XCTAssertEqual(GroupReaction.parse("white_check_mark"), .done)
        for bad in ["", "❤️", "🎉", "ok", "👍👎"] { XCTAssertNil(GroupReaction.parse(bad), bad) }
    }

    func testChipsGroupByMessageAndEmojiInOrderAndCountAMemberOnce() {
        func reaction(_ seq: Int, _ name: String, _ emoji: String, on target: Int) -> GroupMessage {
            GroupMessage(seq: seq, ts: Date(), author: .member(UUID()), name: name, text: "r", target: .everyone,
                         reaction: emoji, reactionTo: target)
        }
        let log = [
            GroupMessage(seq: 1, ts: Date(), author: .human, name: "User", text: "go", target: .everyone),
            reaction(2, "web", "✅", on: 1), reaction(3, "api", "👀", on: 1),
            reaction(4, "api", "✅", on: 1), reaction(5, "web", "✅", on: 1),
        ]
        XCTAssertEqual(GroupReaction.chips(log), [1: [.init(emoji: "👀", names: ["api"]),
                                                      .init(emoji: "✅", names: ["web", "api"])]])
    }
}

@MainActor
final class GroupReactionTests: XCTestCase {
    private var base: URL!
    private var manager: SessionManager!
    private var bridge: BridgeCore!
    private var server: MCPServer!
    private var service: GroupService!
    private var group: ChatGroup!
    private var typed: [(UUID, String)] = []
    private let alice = UUID(), bob = UUID(), carol = UUID(), dave = UUID()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("group-react-\(UUID().uuidString)")
        manager = SessionManager(host: FakeTerminalHost(), executablePath: "/bin/echo", supportDir: base)
        for (name, key, pid) in [("alice", alice, 1), ("bob", bob, 2), ("carol", carol, 3), ("dave", dave, 4)] {
            manager.register(AgentSession(callsign: name, cwd: "/\(name)", claudeSessionID: key.uuidString.lowercased(),
                                          token: name.uppercased()),
                             handle: FakeTerminalHost.Handle(pid: Int32(pid)))
        }
        bridge = BridgeCore(manager: manager, idGenerator: { "id" })
        server = MCPServer(bridge: bridge)
        service = GroupService(store: GroupStore(base: base))
        let peers = [GroupPeer(id: alice, callsign: "alice", status: .idle),
                     GroupPeer(id: bob, callsign: "bob", status: .idle),
                     GroupPeer(id: carol, callsign: "carol", status: .busy),
                     GroupPeer(id: dave, callsign: "dave", status: .idle)]
        service.peers = { peers }
        service.deliver = { [self] id, text in
            guard id != carol else { return false }   // carol's claude refuses typed text, so her wake is held
            typed.append((id, text)); return true
        }
        bridge.groups = service
        group = try service.store.create(name: "Checkout fix", members: [alice, bob, carol]).get()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func call(_ name: String, _ args: [String: Any], as token: String = "BOB") throws -> (ok: Bool, text: String) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": args]]
        let data = server.handle(requestData: try JSONSerialization.data(withJSONObject: request), sessionToken: token)
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (!(result["isError"] as? Bool ?? true), text)
    }

    /// alice (the user's stand-in) says something; returns its seq. Nobody is left typed-to.
    @discardableResult
    private func aliceSays(_ text: String = "the total is fixed") throws -> Int {
        let seq = try XCTUnwrap(try service.post(group: "Checkout fix", from: .member(alice), text: text).get().message).seq
        typed = []
        return seq
    }

    func testAReactionIsLoggedWakesNobodySpendsNothingAndMovesNoCursor() throws {
        let seq = try aliceSays()
        let spent = service.store.group(group.id)?.spent
        let cursorBefore = service.store.cursor(carol, group: group.id)
        let pendingBefore = service.hasPending(carol)   // alice's message is already held for carol, whose delivery failed
        let r = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "👍"])
        XCTAssertTrue(r.ok, r.text)
        XCTAssertEqual(r.text, "reacted 👍 to #\(seq); nobody was woken")
        XCTAssertTrue(typed.isEmpty, "a reaction wakes nobody, not even the author or carol")
        XCTAssertEqual(service.store.group(group.id)?.spent, spent, "and costs no budget")
        XCTAssertEqual(service.store.cursor(carol, group: group.id), cursorBefore)
        XCTAssertEqual(service.hasPending(carol), pendingBefore, "no wake is held for carol either")
        XCTAssertTrue(pendingBefore, "(the fixture's refusing member does hold alice's wake, so the check can fail)")
        let logged = try XCTUnwrap(service.store.messages(group.id).last)
        XCTAssertEqual(logged.author, .member(bob))
        XCTAssertEqual(logged.reaction, "👍")
        XCTAssertEqual(logged.reactionTo, seq)
        XCTAssertEqual(logged.text, "reacted 👍 to #\(seq) (@alice: \"the total is fixed\")")
        XCTAssertEqual(logged.target, .everyone)
    }

    func testAReactionKeepsAGroupFromPausingNoMatterHowManyAreSent() throws {
        let seq = try aliceSays()
        for emoji in ["👀", "👍", "👎", "✅"] { _ = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": emoji]) }
        XCTAssertFalse(service.store.group(group.id)?.isPaused ?? true)
        XCTAssertEqual(service.store.group(group.id)?.spent, 1, "only alice's message was spent")
    }

    func testRefusals() throws {
        let seq = try aliceSays()
        let mine = try XCTUnwrap(try service.post(group: "Checkout fix", from: .member(bob), text: "mine").get().message).seq
        let reactionSeq = try XCTUnwrap(try { _ = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "👀"])
            return service.store.messages(group.id).last?.seq }())
        let count = service.store.messages(group.id).count

        XCTAssertEqual(try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "🎉"]).text,
                       "\"🎉\" is not a reaction; use one of 👀 👍 👎 ✅")
        XCTAssertEqual(try call("group_react", ["group": "Checkout fix", "message": 99, "emoji": "👍"]).text,
                       "no message #99 in this group (use the #id from the prompt or group_log)")
        XCTAssertEqual(try call("group_react", ["group": "Checkout fix", "emoji": "👍"]).text,
                       "message is required: the #id of the message to react to")
        XCTAssertEqual(try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "👍"], as: "DAVE").text,
                       "\"dave\" is not a member of this group")
        XCTAssertEqual(try call("group_react", ["group": "nope", "message": seq, "emoji": "👍"]).text,
                       "no group named or with id \"nope\"")
        XCTAssertEqual(try call("group_react", ["group": "Checkout fix", "message": mine, "emoji": "👍"]).text,
                       "#\(mine) is your own message")
        XCTAssertEqual(try call("group_react", ["group": "Checkout fix", "message": reactionSeq, "emoji": "👍"]).text,
                       "#\(reactionSeq) is a reaction; react to the message it is on (#\(seq))")
        XCTAssertFalse(try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "👍"], as: "NOBODY").ok)
        XCTAssertEqual(service.store.messages(group.id).count, count, "none of the refusals logged anything")
    }

    func testFlagOffThereIsNoToolAndTheServiceRefuses() throws {
        let seq = try aliceSays()
        service.enabled = { false }
        XCTAssertEqual(service.react(group: "Checkout fix", member: bob, to: seq, emoji: "👍"),
                       .failure(.disabled))
        bridge.groups = nil
        service.enabled = { true }
        let r = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "👍"])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.text, "unknown tool: group_react")
        XCTAssertFalse(MCPServer.tools(guidance: "g").contains { $0["name"] as? String == "group_react" })
    }

    func testReactingTwiceWithTheSameEmojiLogsOnce() throws {
        let seq = try aliceSays()
        _ = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "✅"])
        let r = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "white_check_mark"])
        XCTAssertEqual(r.text, "already reacted ✅ to #\(seq)")
        XCTAssertEqual(service.store.messages(group.id).filter(\.isReaction).count, 1)
    }

    func testPromptsAndTheLogLeadEachLineWithItsIdAndShowReactionsAsLines() throws {
        let seq = try aliceSays()
        _ = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "👀"])
        _ = try service.post(group: "Checkout fix", from: .human, text: "thanks").get()
        let log = try call("group_log", ["group": "Checkout fix"], as: "ALICE").text
        XCTAssertEqual(log, "#1 @alice: the total is fixed\n"
                       + "#2 @bob: reacted 👀 to #1 (@alice: \"the total is fixed\")\n#3 User: thanks")

        // A member woken later reads the same ids and the reaction line.
        typed = []
        service.flushPending()
        let prompt = GroupPrompt.text(group: "Checkout fix", members: ["alice", "bob"],
                                      messages: service.store.messages(group.id),
                                      names: [alice: "alice", bob: "bob"])
        XCTAssertTrue(prompt.contains("#2 @bob: reacted 👀 to #1"), prompt)
        XCTAssertTrue(prompt.contains("#3 User: thanks"), prompt)
    }

    func testTheAuthorLearnsOfAReactionOnItsNextWake() throws {
        let seq = try aliceSays()
        _ = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "👍"])
        XCTAssertTrue(typed.isEmpty)
        _ = try service.post(group: "Checkout fix", from: .human, text: "next?").get()
        let toAlice = try XCTUnwrap(typed.first { $0.0 == alice }).1
        XCTAssertTrue(toAlice.contains("#2 @bob: reacted 👍 to #1"), toAlice)
        XCTAssertTrue(toAlice.contains("#3 User: next?"), toAlice)
    }

    func testChipsNameAReactorByItsCurrentCallsign() throws {
        let seq = try aliceSays()
        _ = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "👍"])
        let log = service.store.messages(group.id)
        XCTAssertEqual(GroupReaction.chips(log)[seq]?.first?.names, ["bob"])
        XCTAssertEqual(GroupReaction.chips(log, live: [bob: "bob-renamed"])[seq]?.first?.names, ["bob-renamed"])
    }

    func testReactionsAreNotTimelineRowsNorUnread() throws {
        let seq = try aliceSays()
        _ = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "👍"])
        let log = service.store.messages(group.id)
        let items = GroupAsks.timeline(group: group, messages: log, ledgers: [:])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(GroupSeenCursor.isUnread(log, seen: 1), "a reaction alone is not news")
        XCTAssertTrue(GroupSeenCursor.isUnread(log, seen: 0))
    }

    func testReactionsSurviveTheLogRoundTripAndOldLinesStillDecode() throws {
        let seq = try aliceSays()
        _ = try call("group_react", ["group": "Checkout fix", "message": seq, "emoji": "✅"])
        let reloaded = GroupStore(base: base).messages(group.id)
        XCTAssertEqual(reloaded.last?.reaction, "✅")
        XCTAssertEqual(reloaded.last?.reactionTo, seq)
        // A message that is not a reaction encodes without the new keys: the same bytes as a log
        // line written before reactions existed, and those decode back.
        let plain = GroupMessage(seq: 1, ts: Date(timeIntervalSince1970: 0), author: .human, name: "User",
                                 text: "hi", target: .everyone)
        let line = try GroupFiles.encoder.encode(plain)
        XCTAssertFalse(String(decoding: line, as: UTF8.self).contains("reaction"))
        let decoded = try GroupFiles.decoder.decode(GroupMessage.self, from: line)
        XCTAssertEqual(decoded, plain)
        XCTAssertFalse(decoded.isReaction)
    }

    func testTheToolDescriptionsTellAgentsToReactInsteadOfAcking() throws {
        func description(_ name: String) throws -> String {
            let tool = try XCTUnwrap(MCPServer.tools(guidance: "g", groups: true).first { $0["name"] as? String == name })
            return try XCTUnwrap(tool["description"] as? String)
        }
        XCTAssertTrue(try description("group_say").contains("do NOT post it: use group_react"))
        XCTAssertTrue(try description("group_log").contains("the #id is what group_react takes"))
        XCTAssertTrue(try description("group_list").contains("use group_react"))
        let react = try description("group_react")
        for phrase in ["👀", "👍", "👎", "✅", "instead of sending a message", "wakes nobody", "#id"] {
            XCTAssertTrue(react.contains(phrase), phrase)
        }
    }

    func testGroupSayAsksForShortMessagesAndTablesForLists() throws {
        let tool = try XCTUnwrap(MCPServer.tools(guidance: "g", groups: true).first { $0["name"] as? String == "group_say" })
        let say = try XCTUnwrap(tool["description"] as? String)
        for phrase in ["5–40 words", "1–10 seconds", "markdown table", "final message is never posted"] {
            XCTAssertTrue(say.contains(phrase), phrase)
        }
    }

    func testNoToolOrInstructionMentionsPass() throws {
        let tools = MCPServer.tools(guidance: "g", groups: true).compactMap { $0["description"] as? String }
        for text in tools + [GroupInstructions.text] {
            XCTAssertFalse(text.contains("[pass]"), text)
        }
    }
}
