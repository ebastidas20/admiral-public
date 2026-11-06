import AppKit
import AdmiralCore

/// `-probeTitlebar <proof> [-probeTitlebarTranscript <jsonl>]`: the header drags the window and
/// still works — writes PASS/FAIL lines, then quits. Run it isolated (`ADMIRAL_SUPPORT_DIR` + a
/// unique `ADMIRAL_PROFILE`, `ADMIRAL_DEMO=1` for a selected tab), never against the installed app.
///
/// A header drag is performed by the window server from the drag region AppKit hands it, and
/// SwiftUI subtracts anything hit-testable under the titlebar from that region. When it comes
/// out empty the header looks right and nothing moves — a silent failure only a real drag
/// reveals. So this asserts on the region itself (AppKit's own description of it): the empty
/// header is in it, the toolbar buttons are not, the header still shows the pane color, and the
/// buttons still click. With a transcript it repeats the checks with that tab open in Chat.
extension AppModel {
    func runTitlebarProbe(proof: String, transcript: String?) {
        Task { @MainActor in
            var lines: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String) {
                lines.append("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            }
            func finish() -> Never {
                let failed = lines.contains { $0.hasPrefix("FAIL") }
                lines.insert("titlebar: \(failed ? "FAIL" : "PASS")", at: 0)
                try? (lines.joined(separator: "\n") + "\n").write(toFile: proof, atomically: true, encoding: .utf8)
                exit(failed ? 1 : 0)
            }

            var found: NSWindow?
            for _ in 0..<40 {
                found = NSApp.windows.first { $0.toolbar != nil && $0.isVisible }
                if found != nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let window = found, let frameView = window.contentView?.superview else {
                check("window", false, "no window with a toolbar appeared")
                finish()
            }
            // Clicks only reach an active, key window.
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<30 where !(NSApp.isActive && window.isKeyWindow) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(1))

            let header = NSRect(x: 0, y: window.contentLayoutRect.maxY, width: frameView.bounds.width,
                                height: frameView.bounds.height - window.contentLayoutRect.maxY)
            let midY = header.midY

            func dragRegion() -> [NSRect]? {
                let key = "_lastDragRegionDataDescription"
                guard window.responds(to: Selector((key))),
                      let text = window.value(forKey: key) as? String else { return nil }
                let pattern = try! NSRegularExpression(pattern: #"\{\{[^{}]*\}, \{[^{}]*\}\}"#)
                return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    .compactMap { Range($0.range, in: text).map { NSRectFromString(String(text[$0])) } }
            }
            func views(_ v: NSView, named prefix: String) -> [NSView] {
                (String(describing: type(of: v)).hasPrefix(prefix) ? [v] : [])
                    + v.subviews.flatMap { views($0, named: prefix) }
            }
            func color(_ rep: NSBitmapImageRep, _ p: NSPoint, in shot: NSRect) -> NSColor? {
                let scale = CGFloat(rep.pixelsWide) / shot.width
                return rep.colorAt(x: Int((p.x - shot.minX) * scale),
                                   y: Int((shot.maxY - p.y) * scale))?.usingColorSpace(.sRGB)
            }
            func hex(_ c: NSColor?) -> String {
                guard let c else { return "none" }
                return String(format: "#%02X%02X%02X", Int(c.redComponent * 255),
                              Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            }

            /// The tab-mode header color; Chat must show the same one.
            var tabHeaderColor: String?
            func checkHeader(_ label: String) {
                // Toolbar buttons sit in glass platters; the empty header is the gaps between them.
                let platters = views(frameView, named: "NSToolbarPlatterView")
                    .map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
                let gaps = zip(platters, platters.dropFirst())
                    .map { ($0.maxX, $1.minX) }.filter { $0.1 - $0.0 > 80 }
                guard !gaps.isEmpty else {
                    check("\(label): toolbar", false, "no gap between \(platters.count) button groups")
                    return
                }
                guard let region = dragRegion() else {
                    check("\(label): drag region", false, "AppKit no longer describes the window's drag region")
                    return
                }
                let empty = gaps.flatMap { [$0.0 + 30, ($0.0 + $0.1) / 2, $0.1 - 30] }.map { NSPoint(x: $0, y: midY) }
                let outside = empty.filter { p in !region.contains { $0.contains(p) } }
                check("\(label): empty header drags the window", !region.isEmpty && outside.isEmpty,
                      region.isEmpty ? "the drag region is empty"
                          : outside.isEmpty ? "\(empty.count) points in a \(region.count)-rect region"
                          : "not draggable at x=\(outside.map { Int($0.x) })")
                // Each button's own centre: a platter's midpoint can fall in the gap between two buttons.
                let buttons = views(frameView, named: "NSToolbarPlatterView")
                    .flatMap { views($0, named: "NSToolbarItemViewer") }
                    .map { $0.convert($0.bounds, to: nil) }
                    .map { NSPoint(x: $0.midX, y: $0.midY) }
                let grabbed = buttons.filter { p in region.contains { $0.contains(p) } }
                check("\(label): buttons stay out of the drag region", !buttons.isEmpty && grabbed.isEmpty,
                      buttons.isEmpty ? "no toolbar buttons found"
                          : grabbed.isEmpty ? "\(buttons.count) buttons excluded"
                          : "draggable at x=\(grabbed.map { Int($0.x) })")

                let shot = NSRect(x: 0, y: header.minY - 60, width: header.width, height: header.height + 60)
                guard let rep = frameView.bitmapImageRepForCachingDisplay(in: shot) else {
                    check("\(label): header color", false, "could not render the header")
                    return
                }
                frameView.cacheDisplay(in: shot, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: proof + ".\(label).png"))
                // Away from the title (which follows the leading buttons): each gap's middle and right end.
                let samples = gaps.flatMap { [NSPoint(x: ($0.0 + $0.1) / 2, y: midY), NSPoint(x: $0.1 - 30, y: midY)] }
                let colors = Set(samples.map { hex(color(rep, $0, in: shot)) })
                if let tab = tabHeaderColor {
                    check("\(label): header keeps its color", colors == [tab], "header \(colors.sorted()), tab header \(tab)")
                } else {
                    let pane = hex(color(rep, NSPoint(x: samples[0].x, y: header.minY - 20), in: shot))
                    check("\(label): header shows the pane color", colors == [pane], "header \(colors.sorted()), pane \(pane)")
                    tabHeaderColor = colors.count == 1 ? colors.first : nil
                }
            }

            func click(_ p: NSPoint) async {
                func event(_ type: NSEvent.EventType) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)
                }
                if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
                if let down = event(.leftMouseDown) { NSApp.sendEvent(down) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            /// Click a toolbar toggle twice: it must flip, then flip back (so nothing persists).
            func checkToggle(_ name: String, at x: CGFloat, _ value: () -> Bool) async {
                let before = value()
                await click(NSPoint(x: x, y: midY))
                let flipped = value()
                await click(NSPoint(x: x, y: midY))
                let restored = value()
                check("\(name) button still clicks", flipped != before && restored == before,
                      "\(before) → \(flipped) → \(restored)")
            }

            checkHeader("tab")
            let savedSidebar = sidebarCollapsed, savedFootprint = showTouchedReposPanel
            let platters = views(frameView, named: "NSToolbarPlatterView")
                .map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
            if let leading = platters.first, let trailing = platters.last {
                await checkToggle("sidebar", at: leading.midX) { sidebarCollapsed }
                // The Footprint toggle is the trailing group's last button.
                await checkToggle("footprint", at: trailing.maxX - 20) { showTouchedReposPanel }
            }
            sidebarCollapsed = savedSidebar
            showTouchedReposPanel = savedFootprint

            if let transcript {
                if config.features.chatView {
                    let session = AgentSession(callsign: "probe-chat", cwd: NSHomeDirectory(),
                                               claudeSessionID: "probe-titlebar", transcriptPath: transcript,
                                               status: .idle)
                    sessions.register(session, handle: nil)
                    sessions.selectedID = session.id
                    sessions.refreshConversation(session.id)
                    setViewMode(.chat, for: session)
                    try? await Task.sleep(for: .seconds(2))
                    check("chat: tab shows Chat", viewMode(for: session) == .chat, "mode=\(viewMode(for: session).rawValue)")
                    checkHeader("chat")
                } else {
                    lines.append("SKIP  chat — config.features.chatView is off")
                }
            }
            finish()
        }
    }
}
