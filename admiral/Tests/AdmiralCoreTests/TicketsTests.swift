import XCTest
@testable import AdmiralCore

final class TicketKeyFinderTests: XCTestCase {
    /// Any Jira-shaped key — the finder's mechanics, independent of the shipped default.
    private let jira = [#"\b[A-Z][A-Z0-9]+-\d+\b"#]

    /// The shipped default names this org's projects and nothing else.
    func testDefaultPatternMatchesOnlyTheOrgsProjects() {
        let text = "PROJ-920, ACME-9359, KEY-7 and OPS-1190; not ICD-10, UTF-8, TOP-1000 or DEV-1"
        XCTAssertEqual(TicketKeyFinder.findKeys(in: text, patterns: [AdmiralConfig.TicketsConfig.defaultPattern]),
                       ["OPS-1190", "KEY-7", "ACME-9359", "PROJ-920"])
    }

    func testOrdersKeysByLatestMentionNewestFirst() {
        let text = "Working on PROJ-12 then ABC-3, back to PROJ-12 and X9-100."
        XCTAssertEqual(TicketKeyFinder.findKeys(in: text, patterns: jira), ["X9-100", "PROJ-12", "ABC-3"])
    }

    func testIgnoresLowercaseAndPartialTokens() {
        let text = "proj-12 is not a key, nor is A-1 (single letter) or UTF-8x"
        XCTAssertEqual(TicketKeyFinder.findKeys(in: text, patterns: jira), [])
    }

    func testMultiplePatternsDedupeAcrossPatterns() {
        let patterns = [jira[0], #"#\d{3,}"#, #"\bPROJ-\d+\b"#]
        let text = "PROJ-7 and #1234 and PROJ-7 again"
        XCTAssertEqual(TicketKeyFinder.findKeys(in: text, patterns: patterns), ["PROJ-7", "#1234"])
    }

    func testInvalidRegexIsSkipped() {
        let patterns = ["([unclosed", jira[0]]
        XCTAssertEqual(TicketKeyFinder.findKeys(in: "see OPS-42", patterns: patterns), ["OPS-42"])
    }

    func testScanTextIncludesRepliesAndAskQuestions() {
        let events = [
            ChatEvent(ts: "1", kind: .prompt, text: "please drive OPS-1"),
            ChatEvent(ts: "2", kind: .ask, questions: [
                AskQuestion(question: "Also close WEB-22?", header: "Next",
                            options: [AskOption(label: "Yes", description: "then API-9")]),
            ]),
            ChatEvent(ts: "3", kind: .reply, text: "Done with OPS-1."),
        ]
        let text = TicketKeyFinder.scanText(of: events)
        XCTAssertEqual(TicketKeyFinder.findKeys(in: text, patterns: jira), ["OPS-1", "API-9", "WEB-22"])
    }

    /// Only the user and the agent name the session's tickets. A subagent's report arrives
    /// as a `<task-notification>` prompt citing every ticket in the code it read, and a
    /// prompt Admiral typed is Admiral talking — neither belongs in the panel.
    func testScanTextSkipsSubagentReportsAndAdmiralPrompts() {
        let events = [
            ChatEvent(ts: "1", kind: .prompt, text: "drive OPS-1"),
            ChatEvent(ts: "2", kind: .prompt, text: "  <task-notification>\n<result>slug-safe "
                      + "(OLD-505), swallowed (OLD-826)</result>\n</task-notification>"),
            ChatEvent(ts: "3", kind: .prompt, text: "PR WATCH — BOT-7 merged", source: "admiral"),
            ChatEvent(ts: "4", kind: .needs, text: "Claude needs permission for LOG-3"),
            ChatEvent(ts: "5", kind: .reply, text: "Opened WEB-22 for OPS-1."),
        ]
        let text = TicketKeyFinder.scanText(of: events)
        XCTAssertEqual(TicketKeyFinder.findKeys(in: text, patterns: jira), ["OPS-1", "WEB-22"])
    }

    func testEmptyInputs() {
        XCTAssertEqual(TicketKeyFinder.findKeys(in: "", patterns: jira), [])
        XCTAssertEqual(TicketKeyFinder.findKeys(in: "OPS-1", patterns: []), [])
    }
}

final class TicketsConfigTests: XCTestCase {
    private func decode(_ raw: String) throws -> AdmiralConfig {
        try JSONDecoder().decode(AdmiralConfig.self, from: Data(raw.utf8))
    }

    func testMissingTicketsSectionUsesDefaults() throws {
        let config = try decode(#"{"version": 1, "features": {"chatView": true, "apiServer": true}}"#)
        XCTAssertTrue(config.features.chatView)
        XCTAssertTrue(config.features.apiServer)
        XCTAssertEqual(config.tickets.patterns, [AdmiralConfig.TicketsConfig.defaultPattern])
        XCTAssertEqual(config.tickets.openURLTemplate, "")
        XCTAssertEqual(config.tickets.jira.siteURL, "")
        XCTAssertEqual(config.tickets.jira.clientId, "")
    }

    func testTicketsSectionDecodesAndIgnoresUnknownKeys() throws {
        let config = try decode(#"""
        {"version": 1, "features": {},
         "tickets": {"patterns": ["\\bOPS-\\d+\\b"], "openURLTemplate": "https://x.atlassian.net/browse/{key}",
                     "jira": {"siteURL": "https://x.atlassian.net", "clientId": "abc", "accessToken": "nope"},
                     "future": 1}}
        """#)
        XCTAssertEqual(config.tickets.patterns, [#"\bOPS-\d+\b"#])
        XCTAssertEqual(config.tickets.openURLTemplate, "https://x.atlassian.net/browse/{key}")
        XCTAssertEqual(config.tickets.jira.siteURL, "https://x.atlassian.net")
        XCTAssertEqual(config.tickets.jira.clientId, "abc")
    }

    func testPartialTicketsSectionFillsDefaults() throws {
        let config = try decode(#"{"version": 1, "features": {}, "tickets": {"jira": {"siteURL": "https://y.atlassian.net"}}}"#)
        XCTAssertEqual(config.tickets.patterns, [AdmiralConfig.TicketsConfig.defaultPattern])
        XCTAssertEqual(config.tickets.jira.siteURL, "https://y.atlassian.net")
        XCTAssertEqual(config.tickets.jira.clientId, "")
    }

    func testOpenURLTemplateAndSiteFallback() {
        var t = AdmiralConfig.TicketsConfig()
        XCTAssertNil(t.openURL(for: "OPS-1"))
        t.jira.siteURL = "https://acme.atlassian.net/"
        XCTAssertEqual(t.openURL(for: "OPS-1")?.absoluteString, "https://acme.atlassian.net/browse/OPS-1")
        t.openURLTemplate = "https://tracker.example/{KEY}?k={key}"
        XCTAssertEqual(t.openURL(for: "OPS-1")?.absoluteString, "https://tracker.example/OPS-1?k=OPS-1")
        t.openURLTemplate = "https://acme.atlassian.net/"
        XCTAssertEqual(t.openURL(for: "OPS-1")?.absoluteString, "https://acme.atlassian.net/browse/OPS-1")
    }

    func testRoundTripNeverContainsTokens() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-tickets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var config = AdmiralConfig(features: .init(chatView: true, apiServer: true))
        config.tickets.openURLTemplate = "https://z.atlassian.net/browse/{key}"
        config.tickets.jira = .init(siteURL: "https://z.atlassian.net", clientId: "cid")
        AdmiralConfigStore.save(config, to: url)
        XCTAssertEqual(AdmiralConfigStore.load(from: url), config)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("accessToken"))
        XCTAssertFalse(raw.contains("refreshToken"))
        XCTAssertFalse(raw.contains("clientSecret"))
    }
}

final class JiraStatusParseTests: XCTestCase {
    func testParsesSummaryAndStatusCategory() {
        let json = #"""
        {"id": "10001", "key": "OPS-42",
         "fields": {"summary": "Fix the thing",
                    "status": {"name": "In Review", "statusCategory": {"id": 4, "key": "indeterminate", "name": "In Progress"}}}}
        """#
        let ref = JiraTicketsClient.parseIssue(key: "OPS-42", data: Data(json.utf8))
        XCTAssertEqual(ref, TicketRef(key: "OPS-42", summary: "Fix the thing",
                                      statusName: "In Review", statusCategory: .inProgress))
    }

    func testCategoryMapping() {
        XCTAssertEqual(TicketRef.category(fromJiraKey: "new"), .todo)
        XCTAssertEqual(TicketRef.category(fromJiraKey: "indeterminate"), .inProgress)
        XCTAssertEqual(TicketRef.category(fromJiraKey: "done"), .done)
        XCTAssertEqual(TicketRef.category(fromJiraKey: "weird"), .unknown)
        XCTAssertEqual(TicketRef.category(fromJiraKey: nil), .unknown)
    }

    func testMissingStatusStillParses() {
        let ref = JiraTicketsClient.parseIssue(key: "A1-1", data: Data(#"{"fields": {"summary": "s"}}"#.utf8))
        XCTAssertEqual(ref?.statusName, nil)
        XCTAssertEqual(ref?.statusCategory, .unknown)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(JiraTicketsClient.parseIssue(key: "A1-1", data: Data("nope".utf8)))
    }

    func testAuthorizationURLCarriesPKCEAndRedirect() {
        let pkce = JiraOAuth.makePKCE()
        let url = JiraOAuth.authorizationURL(clientId: "cid", pkce: pkce)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        XCTAssertEqual(url.host, "auth.atlassian.com")
        XCTAssertEqual(v("redirect_uri"), "admiral://oauth/jira")
        XCTAssertEqual(v("scope"), "read:jira-work offline_access")
        XCTAssertEqual(v("code_challenge_method"), "S256")
        XCTAssertEqual(v("code_challenge"), pkce.challenge)
        XCTAssertEqual(v("state"), pkce.state)
        XCTAssertEqual(v("audience"), "api.atlassian.com")
        XCTAssertNotEqual(pkce.verifier, pkce.challenge)
    }
}
