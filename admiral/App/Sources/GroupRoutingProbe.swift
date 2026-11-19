import AppKit
import AdmiralCore

/// `-probeGroupRouting <cwd> -probeGroupRoutingProof <file>`: group chat against two REAL
/// claude tabs. An untagged user message is routed by one real haiku call and wakes the member
/// it names; that member answers with group_say; a tagged member that is told not to reply has
/// nothing posted for it when its turn ends; a renamed tab's messages read by the new name.
/// Writes PASS/FAIL lines, then quits.
///
/// Run it isolated (`ADMIRAL_SUPPORT_DIR` + a unique `ADMIRAL_PROFILE`), from the build
/// products — never against the installed app, which hosts live sessions.
extension AppModel {
    func runGroupRoutingProbe(cwd: String, proof: String) {
        var features = config.features
        features.groups = true
        updateFeatures(features)
        newSession(name: "builder", cwd: cwd)
        newSession(name: "reviewer", cwd: cwd)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var lines: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String) {
                lines.append("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            }
            @MainActor func finish() {
                let failed = lines.contains { $0.hasPrefix("FAIL") }
                lines.insert(failed ? "RESULT: FAIL" : "RESULT: PASS", at: 0)
                try? (lines.joined(separator: "\n") + "\n").write(toFile: proof, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            func poll<T>(_ seconds: Double, _ probe: () -> T?) async -> T? {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    if let value = probe() { return value }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                return nil
            }

            let tabs = Dictionary(sessions.sessions.map { ($0.callsign, $0) }, uniquingKeysWith: { a, _ in a })
            guard let builder = tabs["builder"], let reviewer = tabs["reviewer"] else {
                check("commission", false, "tabs: \(tabs.keys.sorted())")
                return finish()
            }
            for tab in [builder, reviewer] {
                let ready = await poll(90) { () -> Bool? in
                    guard let handle = self.sessions.handle(for: tab.id),
                          let screen = self.host.captureVisibleText(handle), screen.contains("❯") else { return nil }
                    return true
                }
                check("\(tab.callsign) TUI came up", ready == true, ready == true ? "prompt visible" : "no prompt after 90s")
                guard ready == true else { return finish() }
            }
            let builderKey = memberKey(for: builder), reviewerKey = memberKey(for: reviewer)
            guard case .success(let group) = createGroup(name: "routing probe", members: [builderKey, reviewerKey]) else {
                check("group", false, "createGroup failed")
                return finish()
            }
            var routed: (picked: [String]?, woken: [String])?
            let report = groupService.onRouted
            groupService.onRouted = { seq, picked, woken in report(seq, picked, woken); routed = (picked, woken) }
            @MainActor func log() -> [GroupMessage] { groupStore.messages(group.id) }
            @MainActor func says(_ key: UUID, after seq: Int) -> [GroupMessage] {
                log().filter { $0.seq > seq && $0.author == .member(key) && !$0.isReaction }
            }

            // 1. Untagged: the router picks the builder, who answers with group_say.
            let ask = "builder, please post the single word ROUTED in this group with group_say. reviewer, nothing for you."
            guard case .success(let posted) = postGroupMessage(group: group.id, text: ask), let askSeq = posted.message?.seq else {
                check("post", false, "untagged post failed")
                return finish()
            }
            check("an untagged message goes to the router", posted.routing.count == 2 && posted.woken.isEmpty,
                  "routing=\(posted.routing) woken=\(posted.woken)")
            let decision = await poll(40) { routed }
            check("one haiku call picked the builder", decision?.picked == ["builder"],
                  "picked=\(decision?.picked.map(\.description) ?? "<router failed>") woke=\(decision?.woken ?? [])")
            let answer = await poll(150) { says(builderKey, after: askSeq).first }
            check("the woken builder answered with group_say", answer?.text.contains("ROUTED") == true,
                  "builder said: \(answer?.text ?? "<nothing in 150s>")")
            check("the reviewer was not woken", says(reviewerKey, after: askSeq).isEmpty && decision?.woken == ["builder"],
                  "reviewer posts=\(says(reviewerKey, after: askSeq).map(\.text))")

            // 2. Tagged, told not to reply: its turn ends and nothing is posted for it.
            let quietSeq = log().last?.seq ?? 0
            _ = postGroupMessage(group: group.id, text: "@reviewer read this and end your turn without posting or reacting. Reply in your tab with OK.")
            let busy = await poll(60) { self.sessions.sessions.first { $0.id == reviewer.id }?.status == .busy ? true : nil }
            let idle = await poll(150) { () -> Bool? in
                busy == true && self.sessions.sessions.first { $0.id == reviewer.id }?.status == .idle ? true : nil
            }
            try? await Task.sleep(for: .seconds(5))
            check("a turn's final message is not posted to the group", idle == true && says(reviewerKey, after: quietSeq).isEmpty,
                  "turn ended=\(idle == true) reviewer posts=\(says(reviewerKey, after: quietSeq).map(\.text))")

            // 3. Rename: the builder's message reads by the new name at once.
            sessions.rename(builder.id, to: "builder-two")
            let live = Dictionary(groupService.peers().map { ($0.id, $0.callsign) }, uniquingKeysWith: { a, _ in a })
            let shown = answer.map { $0.authorName(live) }
            let wakeLine = answer.map { GroupPrompt.line($0, names: live) }
            check("a renamed tab's messages show the new name", shown == "builder-two" && wakeLine?.hasPrefix("@builder-two:") == true,
                  "bubble=\(shown ?? "-") line=\(wakeLine ?? "-")")
            finish()
        }
    }
}
