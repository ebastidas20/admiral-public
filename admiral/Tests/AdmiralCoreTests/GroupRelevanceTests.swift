import XCTest
@testable import AdmiralCore

final class GroupRelevanceSelectTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testThePickedMembersAreChosenInCandidateOrder() {
        XCTAssertEqual(GroupRelevance.select(candidates: [a, b, c], picked: [c, a], fromHuman: false), [a, c])
    }

    func testAUserMessageAlwaysReachesSomeone() {
        XCTAssertEqual(GroupRelevance.select(candidates: [a, b], picked: [], fromHuman: true), [a, b])
        XCTAssertEqual(GroupRelevance.select(candidates: [a, b], picked: nil, fromHuman: true), [a, b])
    }

    func testAnAgentMessageNobodyNeedsWakesNobody() {
        XCTAssertEqual(GroupRelevance.select(candidates: [a, b], picked: [], fromHuman: false), [])
        XCTAssertEqual(GroupRelevance.select(candidates: [a, b], picked: nil, fromHuman: false), [])
    }

    func testParseMembers() {
        let names = ["api-fix", "web-ui", "qa"]
        XCTAssertEqual(GroupRelevance.parseMembers(#"Sure. {"members": ["Web-UI", "@qa", "ghost"]}"#, candidates: names),
                       ["web-ui", "qa"])
        XCTAssertEqual(GroupRelevance.parseMembers(#"{"members": []}"#, candidates: names), [])
        XCTAssertNil(GroupRelevance.parseMembers("web-ui", candidates: names), "no JSON is a failure, not nobody")
        XCTAssertNil(GroupRelevance.parseMembers(#"{"score": 0.9}"#, candidates: names))
    }

    func testThePromptCarriesTheLastTwentyMessagesAndTheCandidates() {
        let log = (1...25).map {
            GroupMessage(seq: $0, ts: Date(), author: .human, name: "User", text: "m\($0)", target: .everyone)
        }
        let prompt = GroupRelevance.prompt(group: "g", candidates: ["api-fix", "qa"], log: log, names: [:])
        XCTAssertTrue(prompt.contains("#6 User: m6"))
        XCTAssertTrue(prompt.contains("#25 User: m25"))
        XCTAssertFalse(prompt.contains("#5 User: m5\n"))
        XCTAssertTrue(prompt.contains("@api-fix, @qa"))
        XCTAssertTrue(prompt.contains(#"{"members": ["callsign", ...]}"#))
    }
}

@MainActor
final class GroupRelevanceServiceTests: XCTestCase {
    private var base: URL!
    private var store: GroupStore!
    private var service: GroupService!
    private var typed: [UUID] = []
    private final class Router: @unchecked Sendable {
        private let lock = NSLock()
        private var answer: String?
        private var prompts: [String] = []
        func set(_ new: String?) { lock.lock(); answer = new; lock.unlock() }
        func ask(_ prompt: String) -> String? { lock.lock(); defer { lock.unlock() }; prompts.append(prompt); return answer }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return prompts }
    }
    private let router = Router()
    private var api = UUID(), web = UUID(), qa = UUID()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("group-relevance-\(UUID().uuidString)")
        store = GroupStore(base: base)
        service = GroupService(store: store)
        let names = [api: "api-fix", web: "web-ui", qa: "qa"]
        service.peers = { names.map { GroupPeer(id: $0.key, callsign: $0.value, status: .idle) } }
        service.deliver = { [self] id, _ in typed.append(id); return true }
        let router = router
        service.routeMessage = { router.ask($0) }
        _ = try store.create(name: "Checkout fix", members: [api, web, qa]).get()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func post(_ text: String, from: GroupSender, to: [String] = []) async throws -> GroupPostResult {
        let result = try service.post(group: "Checkout fix", from: from, text: text, to: to).get()
        await service.relevanceTask?.value
        return result
    }

    func testAnUntaggedUserMessageWakesTheMembersOneRouterCallPicks() async throws {
        router.set(#"{"members": ["web-ui"]}"#)
        let result = try await post("who can look at the failing build?", from: .human)
        XCTAssertEqual(Set(result.routing), ["api-fix", "web-ui", "qa"])
        XCTAssertEqual(typed, [web])
        XCTAssertEqual(router.calls.count, 1, "one call per message, not one per member")
    }

    func testUntaggedAgentMessageReachesOnlyTheMembersItIsFor() async throws {
        router.set(#"{"members": ["web-ui"]}"#)
        _ = try await post("the api contract changed", from: .member(api))
        XCTAssertEqual(typed, [web])
        XCTAssertFalse(router.calls[0].contains("@api-fix,"), "the sender is never a candidate")
    }

    func testRouterFailureWakesEveryoneForTheUserAndNobodyForAnAgent() async throws {
        router.set(nil)
        _ = try await post("hello", from: .human)
        XCTAssertEqual(Set(typed), [api, web, qa])
        typed = []
        _ = try await post("hello back", from: .member(api))
        XCTAssertTrue(typed.isEmpty)
    }

    func testTheRoutingIsReported() async throws {
        var reported: [(Int, [String]?, [String])] = []
        service.onRouted = { reported.append(($0, $1, $2)) }
        router.set(#"{"members": ["qa"]}"#)
        _ = try await post("qa, run the suite", from: .human)
        XCTAssertEqual(reported.first?.1, ["qa"])
        XCTAssertEqual(reported.first?.2, ["qa"])
    }

    func testTaggedMessageSkipsTheRouter() async throws {
        let result = try await post("@web-ui can you look", from: .member(api))
        XCTAssertTrue(result.routing.isEmpty)
        XCTAssertTrue(router.calls.isEmpty)
        XCTAssertEqual(typed, [web])
    }

    func testAtAllSkipsTheRouter() async throws {
        let result = try await post("@all heads up", from: .member(api))
        XCTAssertTrue(result.routing.isEmpty)
        XCTAssertEqual(Set(typed), [web, qa])
    }

    func testSwitchedOffEveryoneIsWokenAsBefore() async throws {
        service.relevanceEnabled = { false }
        _ = try await post("hello", from: .member(api))
        XCTAssertEqual(Set(typed), [web, qa])
    }
}
