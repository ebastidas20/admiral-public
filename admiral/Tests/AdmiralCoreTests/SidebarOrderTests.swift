import XCTest
@testable import AdmiralCore

@MainActor
final class SidebarOrderTests: XCTestCase {
    private var support: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-\(UUID().uuidString)")
        suite = "admiral.tests.sidebar.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: support)
        defaults.removePersistentDomain(forName: suite)
    }

    private func manager() -> SessionManager {
        SessionManager(host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/none"),
                       executablePath: "/usr/bin/claude",
                       appearanceStore: SessionAppearanceStore(defaults: defaults),
                       openSessionsStore: OpenSessionsStore(defaults: defaults),
                       supportDir: support)
    }

    private func tab(_ name: String, scratch: Bool = false) -> AgentSession {
        AgentSession(callsign: name, agentType: .claudeCode, cwd: "/tmp",
                     claudeSessionID: UUID().uuidString.lowercased(), scratch: scratch)
    }

    private func group(_ name: String) -> ChatGroup { ChatGroup(name: name, members: []) }

    // MARK: - items

    func testFlagOffIsTodaysTabListWhateverIsStored() {
        let a = tab("a"), s = tab("s", scratch: true), b = tab("b"), g = group("g")
        // A stored order that puts the group first and the tabs reversed.
        let stored = [g.id, b.stableKey, a.stableKey]
        let items = SidebarOrder.items(stored: stored, sessions: [a, s, b], groups: [g], groupsEnabled: false)
        XCTAssertEqual(items, [.session(a.id), .session(b.id)],
                       "flag off: no group, scratch excluded, tabs in the sessions array's order")
    }

    func testFlagOnWithNoGroupsIsTodaysTabList() {
        let a = tab("a"), b = tab("b")
        XCTAssertEqual(SidebarOrder.items(stored: [], sessions: [a, b], groups: [], groupsEnabled: true),
                       [.session(a.id), .session(b.id)])
    }

    func testStoredOrderPlacesGroupsBetweenTabs() {
        let a = tab("a"), b = tab("b"), g = group("g")
        let items = SidebarOrder.items(stored: [a.stableKey, g.id, b.stableKey], sessions: [a, b],
                                       groups: [g], groupsEnabled: true)
        XCTAssertEqual(items, [.session(a.id), .group(g.id), .session(b.id)])
    }

    func testStaleIdsDroppedNewItemsAppendedTabsFirst() {
        let a = tab("a"), b = tab("b"), g1 = group("g1"), g2 = group("g2")
        let gone = UUID(), goneGroup = UUID()
        let items = SidebarOrder.items(stored: [gone, g1.id, a.stableKey, goneGroup], sessions: [a, b],
                                       groups: [g1, g2], groupsEnabled: true)
        XCTAssertEqual(items, [.group(g1.id), .session(a.id), .session(b.id), .group(g2.id)])
        XCTAssertFalse(items.map(\.id).contains(gone))
        XCTAssertFalse(items.map(\.id).contains(goneGroup))
    }

    func testScratchTabsNeverInTheList() {
        let a = tab("a"), s = tab("s", scratch: true), g = group("g")
        let items = SidebarOrder.items(stored: [s.stableKey, g.id, a.stableKey], sessions: [s, a],
                                       groups: [g], groupsEnabled: true)
        XCTAssertEqual(items, [.group(g.id), .session(a.id)])
    }

    func testSessionsArrayDecidesTabOrderEvenAgainstStaleStore() {
        let a = tab("a"), b = tab("b"), g = group("g")
        // Stored says a, g, b — but the tabs were reordered while the flag was off.
        let items = SidebarOrder.items(stored: [a.stableKey, g.id, b.stableKey], sessions: [b, a],
                                       groups: [g], groupsEnabled: true)
        XCTAssertEqual(items, [.session(b.id), .group(g.id), .session(a.id)])
    }

    // MARK: - navigation

    func testNextAndPreviousWrap() {
        XCTAssertEqual(SidebarOrder.next(after: 2, count: 3), 0)
        XCTAssertEqual(SidebarOrder.next(after: 0, count: 3), 1)
        XCTAssertEqual(SidebarOrder.next(after: nil, count: 3), 0)
        XCTAssertEqual(SidebarOrder.previous(before: 0, count: 3), 2)
        XCTAssertEqual(SidebarOrder.previous(before: nil, count: 3), 2)
        XCTAssertNil(SidebarOrder.next(after: nil, count: 0))
        XCTAssertNil(SidebarOrder.previous(before: nil, count: 0))
    }

    func testNavigationNeverLandsOnScratch() {
        let a = tab("a"), s = tab("s", scratch: true), b = tab("b"), g = group("g")
        let items = SidebarOrder.items(stored: [], sessions: [a, s, b], groups: [g], groupsEnabled: true)
        var index: Int? = nil
        var visited: [SidebarItem] = []
        for _ in 0..<(items.count * 2) {
            index = SidebarOrder.next(after: index, count: items.count)
            visited.append(items[index!])
        }
        XCTAssertFalse(visited.contains(.session(s.id)))
        XCTAssertEqual(Set(visited), [.session(a.id), .session(b.id), .group(g.id)])
    }

    // MARK: - moves

    func testMoveBeforeAndByDelta() {
        let x = SidebarItem.session(UUID()), y = SidebarItem.group(UUID()), z = SidebarItem.session(UUID())
        XCTAssertEqual(SidebarOrder.move(z, before: x, in: [x, y, z]), [z, x, y])
        XCTAssertEqual(SidebarOrder.move(x, before: z, in: [x, y, z]), [y, x, z])
        XCTAssertEqual(SidebarOrder.move(y, by: -1, in: [x, y, z]), [y, x, z])
        XCTAssertEqual(SidebarOrder.move(y, by: 5, in: [x, y, z]), [x, z, y], "clamped at the end")
        XCTAssertEqual(SidebarOrder.move(x, by: -1, in: [x, y, z]), [x, y, z])
        let unknown = SidebarItem.group(UUID())
        XCTAssertEqual(SidebarOrder.move(unknown, by: 1, in: [x, y, z]), [x, y, z])
        XCTAssertEqual(SidebarOrder.move(x, before: unknown, in: [x, y, z]), [x, y, z])
    }

    /// After any move, the sessions array's permanent tabs read in the list's tab order.
    func testSyncKeepsSessionsArrayInStepWithTheList() {
        let m = manager()
        let a = m.commission(callsign: "a", cwd: "/tmp")
        let s = m.commission(callsign: "s", cwd: "/tmp", scratch: true)
        let b = m.commission(callsign: "b", cwd: "/tmp")
        let c = m.commission(callsign: "c", cwd: "/tmp")
        let g = group("g")
        var items = SidebarOrder.items(stored: [], sessions: m.sessions, groups: [g], groupsEnabled: true)

        func check(_ moved: SidebarItem, _ newItems: [SidebarItem], file: StaticString = #filePath, line: UInt = #line) {
            items = newItems
            SidebarOrder.syncSessions(m, to: items, moved: moved)
            let tabOrder = items.compactMap { if case .session(let id) = $0 { return id } else { return nil } }
            XCTAssertEqual(m.sessions.filter { !$0.scratch }.map(\.id), tabOrder, file: file, line: line)
            // And the list rebuilt from the array + the stored keys is the same list.
            let rebuilt = SidebarOrder.items(stored: SidebarOrder.keys(items, sessions: m.sessions),
                                             sessions: m.sessions, groups: [g], groupsEnabled: true)
            XCTAssertEqual(rebuilt, items, file: file, line: line)
        }
        check(.session(c.id), SidebarOrder.move(.session(c.id), before: .session(a.id), in: items))
        check(.session(c.id), SidebarOrder.move(.session(c.id), by: 10, in: items))
        check(.group(g.id), SidebarOrder.move(.group(g.id), by: -2, in: items))
        check(.session(a.id), SidebarOrder.move(.session(a.id), before: .group(g.id), in: items))
        check(.session(b.id), SidebarOrder.move(.session(b.id), by: -1, in: items))
        XCTAssertTrue(m.sessions.contains { $0.id == s.id }, "the scratch tab is untouched")
    }

    // MARK: - search

    func testGroupSearchMatchesNameOrMember() {
        let g = ChatGroup(name: "Release", members: [])
        XCTAssertTrue(SidebarOrder.groupMatches(g, query: "", memberNames: []))
        XCTAssertTrue(SidebarOrder.groupMatches(g, query: "rel", memberNames: []))
        XCTAssertTrue(SidebarOrder.groupMatches(g, query: "API", memberNames: ["api-fix"]))
        XCTAssertFalse(SidebarOrder.groupMatches(g, query: "web", memberNames: ["api-fix"]))
    }

    // MARK: - persistence

    func testOrderStoreRoundTrip() {
        let keys = [UUID(), UUID(), UUID()]
        SidebarOrderStore(base: support).save(keys)
        XCTAssertEqual(SidebarOrderStore(base: support).order, keys)
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("groups/sidebar-order.json").path))
    }

    func testOrderStoreStartsEmpty() {
        XCTAssertEqual(SidebarOrderStore(base: support).order, [])
    }

    // MARK: - groups and tabs

    func testDeletingAGroupLeavesItsTabs() {
        let m = manager()
        let a = m.commission(callsign: "a", cwd: "/tmp"), b = m.commission(callsign: "b", cwd: "/tmp")
        let store = GroupStore(base: support)
        let g = try! store.create(name: "pair", members: [a.stableKey, b.stableKey]).get()
        store.delete(g.id)
        XCTAssertEqual(m.sessions.map(\.id), [a.id, b.id])
        XCTAssertEqual(SidebarOrder.items(stored: [g.id], sessions: m.sessions, groups: store.groups, groupsEnabled: true),
                       [.session(a.id), .session(b.id)])
    }

    func testDeletingATabTellsItsGroupsByStableKey() {
        let m = manager()
        let a = m.commission(callsign: "a", cwd: "/tmp"), b = m.commission(callsign: "b", cwd: "/tmp"),
            c = m.commission(callsign: "c", cwd: "/tmp")
        let store = GroupStore(base: support)
        let g = try! store.create(name: "trio", members: [a.stableKey, b.stableKey, c.stableKey]).get()
        m.onDelete = { store.removeSession($0.stableKey) }
        m.delete(b.id)
        XCTAssertEqual(store.group(g.id)?.members, [a.stableKey, c.stableKey])
    }

    /// A tab closed and restored under the same claude session id gets a fresh tab id but
    /// keeps its key, so its group still finds it.
    func testMembershipSurvivesRestoreUnderAFreshTabID() {
        let m = manager()
        let sid = UUID().uuidString.lowercased()
        let first = m.commission(callsign: "a", cwd: "/tmp", sessionID: sid)
        let other = m.commission(callsign: "b", cwd: "/tmp")
        let store = GroupStore(base: support)
        let g = try! store.create(name: "pair", members: [first.stableKey, other.stableKey]).get()

        // Relaunch: a new manager restores the same claude session under a new tab id.
        let relaunched = manager()
        let restored = relaunched.commission(callsign: "a", cwd: "/tmp", sessionID: sid, resume: true)
        XCTAssertNotEqual(restored.id, first.id)
        XCTAssertEqual(restored.stableKey, first.stableKey)
        let reloadedStore = GroupStore(base: support)
        let member = reloadedStore.group(g.id)!.members[0]
        XCTAssertEqual(GroupMembers.session(forKey: member, in: relaunched.sessions)?.id, restored.id)
        XCTAssertEqual(GroupMembers.peers(relaunched.sessions).first?.id, member)
    }

    /// Renaming a tab renames it in its groups at once: a member's handle is the name the tab
    /// shows, not the callsign it was created with.
    func testARenamedTabIsNamedByItsNewNameInGroups() {
        let m = manager()
        let tab = m.commission(callsign: "a", cwd: "/tmp")
        m.rename(tab.id, to: "api-v2")
        XCTAssertEqual(GroupMembers.peers(m.sessions).first?.callsign, "api-v2")
    }

    func testStableKeyFallsBackToTabID() {
        let bare = AgentSession(callsign: "x", agentType: .claudeCode, cwd: "/tmp")
        XCTAssertEqual(bare.stableKey, bare.id)
    }
}
