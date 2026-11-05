import AppKit
import SwiftUI
import AdmiralCore

/// `-probeSchedule <cwd> -probeScheduleProof <file>`: scheduled runs against a REAL claude —
/// the part unit tests can't reach (a cron firing on the app's own tick, claude's TUI taking the
/// typed prompt, the Stop hook holding a turn to its output schema). Drives the `schedule_*`
/// tools the way a tab does, renders the Schedules sheet next to the proof (`<file>.png`),
/// writes PASS/FAIL lines, then quits.
///
/// Run it isolated (`ADMIRAL_SUPPORT_DIR` + a unique `ADMIRAL_PROFILE`), from the build
/// products — never against the installed app, which hosts live sessions.
/// The `model` field of a transcript line, whichever JSON spacing it uses.
private func transcriptModelField(of line: String) -> String? {
    guard let range = line.range(of: #""model"\s*:\s*"([^"]+)""#, options: .regularExpression)
    else { return nil }
    return String(line[range]).split(separator: "\"").last.map(String.init)
}

extension AppModel {
    func runScheduleProbe(cwd: String, proof: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var lines: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String) {
                lines.append("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            }
            @MainActor func call(_ tool: String, _ args: [String: Any]) -> (text: String, isError: Bool) {
                let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                              "params": ["name": tool, "arguments": args]]
                guard let body = try? JSONSerialization.data(withJSONObject: request) else { return ("", true) }
                // Admiral itself is calling, not a tab: a session token here names no tab
                // and would be refused.
                let data = self.mcp.handle(requestData: body, caller: .operator)
                let result = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["result"]
                    as? [String: Any] ?? [:]
                return ((result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "",
                        result["isError"] as? Bool ?? true)
            }
            func poll<T>(_ seconds: Double, _ probe: () -> T?) async -> T? {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end {
                    if let value = probe() { return value }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                return nil
            }
            @MainActor func finishedRun(of name: String) -> ScheduleRun? {
                guard let schedule = self.scheduler.schedule(named: name),
                      let run = self.scheduler.store.runs(for: schedule.id).first, run.status != .running
                else { return nil }
                return run
            }
            @MainActor func finish() {
                let failed = lines.contains { $0.hasPrefix("FAIL") }
                lines.insert(failed ? "RESULT: FAIL" : "RESULT: PASS", at: 0)
                try? (lines.joined(separator: "\n") + "\n").write(toFile: proof, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }

            check("this instance runs the schedules", self.holdsSchedules, "SchedulerLock taken")

            // 1. A cron run: "* * * * *" fires at the next minute on the app's own tick.
            let name = "probe-schedule"
            let prompt = "Reply with one short sentence confirming you got this scheduled prompt."
            let created = call("schedule_set", ["name": "probe schedule", "cron": "* * * * *", "cwd": cwd,
                                                "prompt": prompt])
            check("schedule_set creates it under the tab-name rule",
                  !created.isError && created.text.contains("created schedule \(name)"), created.text)
            let run = await poll(260) { finishedRun(of: name) }
            // One fire is the proof; don't leave it firing every minute.
            _ = call("schedule_set", ["name": name, "enabled": false])
            check("the cron fired a run that succeeded", run?.status == .succeeded && run?.trigger == .cron,
                  run.map { "\($0.status.rawValue) \($0.trigger.rawValue) \($0.note ?? "")" } ?? "no finished run after 260s")
            let tab = sessions.sessions.first { $0.claudeSessionID != nil && $0.claudeSessionID == run?.sessionID }
            check("its tab is a new scratch tab named exactly after the schedule, in the folder",
                  tab?.displayTitle == name && tab?.scratch == true && tab?.cwd == cwd,
                  tab.map { "@\($0.displayTitle) scratch=\($0.scratch) cwd=\($0.cwd)" } ?? "no tab with the run's session")
            let detail = run.flatMap { scheduler.detail(runID: $0.id) }
            let transcript = detail?.transcriptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
            let reply = detail?.result?.reply ?? ""
            check("its transcript holds the prompt and a reply", transcript.contains(prompt) && !reply.isEmpty,
                  "reply=\(String(reflecting: String(reply.prefix(120))))")
            /// The model a run's claude served, from its transcript — whatever the machine's
            /// provider routing mapped the alias to. (The first `"model"`-bearing line is an
            /// attachment's `"type":"model"`, so every line is tried for the key form.)
            func servedModel(of transcript: String) -> String {
                for line in transcript.split(separator: "\n") {
                    if let model = transcriptModelField(of: String(line)) { return model }
                }
                return "(no model field)"
            }
            let defaultRunModel = servedModel(of: transcript)
            let history = call("schedule_history", ["name": name])
            check("schedule_history lists the run and points at its session",
                  !history.isError && history.text.contains(run?.id ?? "?") && history.text.contains(run?.sessionID ?? "?"),
                  history.text)

            // 2. A run with an output schema on a named model and effort, started by hand.
            let schemaName = "probe-schema"
            let schema = #"{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}"#
            let createdSchema = call("schedule_set", ["name": schemaName, "cron": "0 3 1 1 *", "cwd": cwd,
                                                      "prompt": "What is two plus two? One word.",
                                                      "output_schema": schema,
                                                      "model": "haiku", "effort": "low"])
            check("schedule_set takes an output schema", !createdSchema.isError, createdSchema.text)
            check("schedule_set answers with the named model and effort",
                  createdSchema.text.contains("model haiku") && createdSchema.text.contains("low effort"),
                  createdSchema.text)
            let started = call("schedule_run", ["name": schemaName])
            check("schedule_run starts a run at once", !started.isError && started.text.contains("@\(schemaName)"),
                  started.text)
            let schemaRun = await poll(260) { finishedRun(of: schemaName) }
            check("the schema run succeeded", schemaRun?.status == .succeeded,
                  schemaRun.map { "\($0.status.rawValue) \($0.note ?? "")" } ?? "no finished run after 260s")
            let schemaTranscript = schemaRun.flatMap { scheduler.detail(runID: $0.id) }?.transcriptPath
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
            let namedModel = servedModel(of: schemaTranscript)
            check("the run's claude really ran on the named model (haiku, not the opus default)",
                  namedModel != defaultRunModel, "default run: \(defaultRunModel) · haiku run: \(namedModel)")
            let detailText = call("schedule_history", ["run_id": schemaRun?.id ?? ""])
            check("schedule_history returns its structured output, read back from the transcript",
                  detailText.text.contains("structured output:") && detailText.text.contains("\"answer\""),
                  detailText.text)

            // 3. What is scheduled, and the sheet that shows it.
            let list = call("schedule_list", [:])
            check("schedule_list shows both", list.text.contains(name) && list.text.contains(schemaName), list.text)
            check("schedule_list shows each one's model (opus by default) and the named effort",
                  list.text.contains("model opus") && list.text.contains("model haiku")
                      && list.text.contains("effort low"), list.text)
            let snapshot = proof + ".png"
            let rendered = await renderSchedulesSheet(to: snapshot)
            check("the Schedules sheet renders", rendered, snapshot)

            // Leave nothing behind but the proof.
            _ = call("schedule_delete", ["name": name])
            _ = call("schedule_delete", ["name": schemaName])
            for session in sessions.sessions where [name, schemaName].contains(session.displayTitle) {
                sessions.delete(session.id)
            }
            finish()
        }
    }

    /// The Schedules sheet drawn offscreen into a PNG.
    private func renderSchedulesSheet(to path: String) async -> Bool {
        await renderOffscreen(SchedulesWindow(), size: NSSize(width: 920, height: 600), to: path)
    }

    /// A view drawn offscreen into a PNG. `ImageRenderer` can't draw text fields or scroll
    /// views, so it goes through a real (unshown) window instead.
    /// `inspect` sees the laid-out view before it is torn down (e.g. to read its accessibility tree).
    func renderOffscreen<V: View>(
        _ view: V, size: NSSize, dark: Bool = true, to path: String, inspect: (NSView) -> Void = { _ in }
    ) async -> Bool {
        let hosting = NSHostingView(rootView: view.environmentObject(self)
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(800))   // let onAppear load the schedules
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        inspect(hosting)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// `-probeSchedulesUI <dir>`: the Schedules UI drawn into `<dir>` with no claude — this
    /// (isolated) support folder gets a schedule in each state, then the real sidebar (expanded
    /// and collapsed) and the Schedules sheet are rendered, dark and light. Same isolation rule
    /// as `-probeSchedule`. The sidebar's collapse flag lives in the shared defaults, so it is
    /// put back before quitting.
    func runSchedulesUIProbe(dir: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            self.seedSchedulesForUIProbe(cwd: dir)
            let collapsed = self.sidebarCollapsed
            for dark in [true, false] {
                let suffix = dark ? "" : "-light"
                self.sidebarCollapsed = false
                _ = await self.renderOffscreen(SidebarView(), size: NSSize(width: 272, height: 520), dark: dark,
                                               to: dir + "/sidebar\(suffix).png")
                self.sidebarCollapsed = true
                _ = await self.renderOffscreen(SidebarView(), size: NSSize(width: 64, height: 520), dark: dark,
                                               to: dir + "/sidebar-collapsed\(suffix).png")
                self.sidebarCollapsed = collapsed
                _ = await self.renderOffscreen(SchedulesWindow(), size: NSSize(width: 920, height: 600), dark: dark,
                                               to: dir + "/sheet\(suffix).png")
            }
            NSApp.terminate(nil)
        }
    }

    /// Three schedules: one whose latest run failed, one with a schema whose late run followed
    /// missed fires, and a paused one.
    func seedSchedulesForUIProbe(cwd: String) {
        let schema = #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}"#
        let now = Date()
        func at(_ hoursAgo: Double) -> Date { now.addingTimeInterval(-hoursAgo * 3600) }
        let seeds: [(spec: ScheduleSpec, runs: [ScheduleRun])] = [
            (ScheduleSpec(name: "nightly-triage", cron: "0 2 * * *", cwd: cwd,
                          prompt: "Triage last night's failures and tell me what needs me.", enabled: true),
             [ScheduleRun(trigger: .cron, status: .succeeded, scheduledFor: at(48), startedAt: at(48), endedAt: at(47.9)),
              ScheduleRun(trigger: .cron, status: .failed, scheduledFor: at(24), startedAt: at(24), endedAt: at(23.99),
                          note: "the prompt never reached claude")]),
            (ScheduleSpec(name: "pr-sweep", cron: "*/30 9-18 * * 1-5", cwd: cwd,
                          prompt: "Sweep my open PRs and report what moved.", outputSchema: schema, enabled: true),
             [ScheduleRun(trigger: .cron, status: .missed, scheduledFor: at(5), startedAt: at(3), endedAt: at(3),
                          note: "3 earlier runs were missed while Admiral was closed or the Mac asleep"),
              ScheduleRun(trigger: .late, status: .succeeded, scheduledFor: at(3.5), startedAt: at(3), endedAt: at(2.9))]),
            (ScheduleSpec(name: "weekly-report", cron: "0 9 * * 1", cwd: cwd,
                          prompt: "Write the weekly report.", enabled: false),
             [ScheduleRun(trigger: .cron, status: .succeeded, scheduledFor: at(100), startedAt: at(100), endedAt: at(99.8))]),
        ]
        for seed in seeds {
            guard case let .success(schedule) = scheduler.set(seed.spec) else { continue }
            for run in seed.runs { scheduler.store.record(run, for: schedule.id) }
        }
    }
}
