import AppKit
import SwiftTerm
import AdmiralCore

/// `TerminalHost` backed by SwiftTerm's `LocalProcessTerminalView`. Spawns the agent
/// in a real PTY, exposes the child PID, and hands the view to SwiftUI for embedding.
@MainActor
final class SwiftTermHost: TerminalHost {
    /// Owns the terminal view and acts as its process delegate — and as its
    /// `terminalDelegate`, because link clicks only dispatch there (see init).
    final class Handle: NSObject, TerminalHandle, LocalProcessTerminalViewDelegate, TerminalViewDelegate {
        let view: LocalProcessTerminalView
        private let onExit: @Sendable (Int32?) -> Void
        /// The child's working directory — seeded at launch, kept fresh via OSC 7. Used to
        /// resolve workspace-relative link clicks (see `requestOpenLink`).
        private var cwd: String

        init(view: LocalProcessTerminalView, cwd: String, onExit: @escaping @Sendable (Int32?) -> Void) {
            self.view = view
            self.cwd = cwd
            self.onExit = onExit
            super.init()
            view.processDelegate = self
            // Link clicks dispatch to `terminalDelegate`, which LocalProcessTerminalView sets
            // to ITSELF and never forwards to `processDelegate` — a `requestOpenLink` there is
            // dead code, and clicks hit SwiftTerm's default (`URL(string:) + NSWorkspace.open`,
            // OSStatus -50 on the scheme-less paths claude emits). Subclassing can't fix it
            // either: the default lives in a protocol extension, so an override is never
            // reached through the protocol witness. Take over as terminalDelegate and proxy
            // every other callback back to the view — the pattern LocalProcessTerminalView's
            // own docs prescribe for replacing its delegate. Verified headless via
            // `-probeLinkWiring`; a missed proxy method would silently revert that callback
            // to SwiftTerm's default (e.g. `send` breaks all keyboard input), so when
            // SwiftTerm grows a new delegate requirement, forward it below.
            view.terminalDelegate = self
        }

        var pid: Int32? {
            let value = view.process?.shellPid ?? 0
            return value == 0 ? nil : value
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        /// Satisfies BOTH delegate protocols (same signature). As terminalDelegate this is
        /// called directly; it must NOT forward to the view, whose implementation would
        /// bounce it back here via processDelegate — infinite recursion.
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let dir = directory, !dir.isEmpty else { return }
            if dir.hasPrefix("file://"), let url = URL(string: dir) { cwd = url.path } else { cwd = dir }
        }
        func processTerminated(source: TerminalView, exitCode: Int32?) { onExit(exitCode) }

        /// Open a clicked terminal link (the terminalDelegate hook — see init). SwiftTerm's
        /// default (`URL(string:) + NSWorkspace.open`) fails with -50 on the bare paths
        /// claude emits (e.g. `.output/specs/foo.md`, `/private/tmp/…/design.md`); resolve
        /// against `cwd` into a real file URL first. A link picked out of rendered prose
        /// carries the sentence's full stop (`…/review.md.`), so that is forgiven too.
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            TerminalLink.resolveInProse(link, cwd: cwd).perform()
        }

        // MARK: TerminalViewDelegate proxies — the view is the original delegate and these
        // callbacks are its plumbing (PTY resize/input, clipboard); hand them straight back.
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            view.sizeChanged(source: source, newCols: newCols, newRows: newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) {
            view.setTerminalTitle(source: source, title: title)
        }
        /// Set by `captureResponses` so a probe can read what the emulator reports back
        /// (e.g. an OSC 4 palette query). nil in normal operation.
        var onSend: ((ArraySlice<UInt8>) -> Void)?
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onSend?(data)
            view.send(source: source, data: data)
        }
        func scrolled(source: TerminalView, position: Double) {
            view.scrolled(source: source, position: position)
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            view.rangeChanged(source: source, startY: startY, endY: endY)
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            view.clipboardCopy(source: source, content: content)
        }
        func clipboardRead(source: TerminalView) -> Data? {
            view.clipboardRead(source: source)
        }
        // The view implements neither of these; mirror SwiftTerm's protocol-extension defaults.
        func bell(source: TerminalView) { NSSound.beep() }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }

    /// The 16 base ANSI colors SwiftTerm installs by default (its `terminalAppColors`).
    /// Reproduced here because installing a palette is the only public way to force a
    /// rebuild of colors 16–255 — see `pinStandardPalette`. Same values, so the base 16
    /// look identical; only the derived cube changes.
    private static let basePalette: [SwiftTerm.Color] = [
        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
    ].map { SwiftTerm.Color(red: $0.0 * 257, green: $0.1 * 257, blue: $0.2 * 257) }

    /// Restore the standard xterm 6×6×6 cube + gray ramp for colors 16–255.
    ///
    /// SwiftTerm defaults `ansi256PaletteStrategy` to `.base16Lab`, which *derives* those
    /// 240 colors by LAB-interpolating the base 16 against the terminal's current
    /// background and foreground — and `Terminal.backgroundColor`/`foregroundColor` rebuild
    /// the palette on every assignment. Admiral sets `nativeBackgroundColor` to the themed
    /// surface, so the whole cube gets dragged toward the theme: on the dark surface index
    /// 230 renders `#94917a` instead of `#ffffd7`, which is why 256-color TUIs look washed
    /// out in dark mode and correct in light. Pin the strategy, then `installPalette` —
    /// setting the strategy alone changes nothing, since the palette was already built
    /// during `Terminal.init` and only these two paths trigger a rebuild.
    ///
    /// Applied once per spawn: on macOS `setupOptions` (the only place SwiftTerm reassigns
    /// `Terminal.options`) runs from the view's `init`, so a resize cannot revert this.
    private static func pinStandardPalette(_ view: LocalProcessTerminalView) {
        let terminal = view.getTerminal()
        terminal.options.ansi256PaletteStrategy = .xterm
        terminal.installPalette(colors: basePalette)
    }

    /// The appearance the terminals are themed for. `AppModel` pushes it from `themeMode`
    /// (the one place that decision is made) rather than each view reading the system, which
    /// is wrong whenever the theme is pinned against a differently-set macOS. Setting it
    /// re-themes the terminals that already exist — the colors are baked in at assignment,
    /// so nothing re-resolves them on its own.
    var appearance: NSAppearance = .currentDrawing() {
        didSet {
            guard appearance.name != oldValue.name else { return }
            reapplyColors()
        }
    }

    /// Re-themes the existing terminals when the palette changes under an unchanged appearance.
    func reapplyColors() {
        for handle in handles.values { applyColors(to: handle.view) }
    }

    /// Foreground/background for the current `appearance`, as **static** colors.
    /// See `Theme.resolved` for why they cannot be the dynamic ones.
    private func applyColors(to view: LocalProcessTerminalView) {
        // Was `configureNativeColors()`, which assigns the dynamic `NSColor.textColor` /
        // `.textBackgroundColor`; same colors, resolved for the app's appearance instead of
        // the system's. The background matches the app surface so the terminal's black is
        // the same as the sidebar's.
        view.nativeForegroundColor = Theme.resolved(.textColor, in: appearance)
        let background = Theme.resolved(Theme.surfaceNS, in: appearance)
        view.nativeBackgroundColor = background
        // The layer paints the default background, and SwiftTerm only sets it once, at creation.
        view.layer?.backgroundColor = background.cgColor
        // AFTER the colors are set: assigning them is what rebuilds the 256-color palette,
        // so pinning the standard cube has to be the last word.
        Self.pinStandardPalette(view)
        view.needsDisplay = true
    }

    private var handles: [ObjectIdentifier: Handle] = [:]
    private var shiftEnterMonitor: Any?
    /// Called (on the main actor) when a hosted terminal emits a claude notification
    /// (OSC 9 / OSC 777). The view identifies the session; String is the message text.
    var onNotification: ((LocalProcessTerminalView, String) -> Void)?

    init() {
        // Shift+Enter inserts an in-prompt newline instead of submitting. Without the
        // kitty keyboard protocol active, AppKit collapses Shift+Return into plain Return
        // (submit), so the Shift is lost. SwiftTerm's keyDown is non-open (can't subclass),
        // so a local key monitor catches Shift+Return while a terminal holds focus and
        // sends the `\`+Enter continuation claude treats as a newline.
        shiftEnterMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                guard event.keyCode == 36,  // main Return
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
                      let term = SwiftTermHost.focusedTerminalView() else { return event }
                term.send(txt: "\\\r")
                return nil  // consume so it doesn't also submit
            }
        }
    }

    deinit { if let m = shiftEnterMonitor { NSEvent.removeMonitor(m) } }

    /// The terminal view currently holding keyboard focus, if any (walk up from the
    /// first responder so an inner subview still resolves to its terminal).
    private static func focusedTerminalView() -> LocalProcessTerminalView? {
        var responder = NSApp.keyWindow?.firstResponder as? NSView
        while let v = responder {
            if let term = v as? LocalProcessTerminalView { return term }
            responder = v.superview
        }
        return nil
    }

    func spawn(
        executable: String,
        args: [String],
        env: [String: String],
        cwd: String,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) -> TerminalHandle {
        let view = AdmiralTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        applyColors(to: view)
        registerNotificationHandlers(on: view)

        let handle = Handle(view: view, cwd: cwd, onExit: onExit)
        let envArray = env.map { "\($0.key)=\($0.value)" }
        view.startProcess(executable: executable, args: args, environment: envArray, currentDirectory: cwd)
        handles[ObjectIdentifier(handle)] = handle
        return handle
    }

    /// Capture claude's notification escapes and forward them to `onNotification`.
    private func registerNotificationHandlers(on view: LocalProcessTerminalView) {
        let terminal = view.getTerminal()
        let report: (String) -> Void = { [weak self, weak view] text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, let view else { return }
                MainActor.assumeIsolated { self.onNotification?(view, trimmed) }
            }
        }
        // OSC 9 ; <text> — iTerm2-style notification. `9;4;…` is a progress report; skip it.
        terminal.registerOscHandler(code: 9) { data in
            let s = String(decoding: data, as: UTF8.self)
            guard !s.hasPrefix("4;"), s != "4" else { return }
            report(s)
        }
        // OSC 777 ; notify ; <title> ; <body>
        terminal.registerOscHandler(code: 777) { data in
            let parts = String(decoding: data, as: UTF8.self).components(separatedBy: ";")
            guard parts.count >= 3, parts[0] == "notify" else { return }
            report(parts[2...].joined(separator: ";"))
        }
    }

    func send(_ handle: TerminalHandle, text: String) {
        (handle as? Handle)?.view.send(txt: text)
    }

    func sendRaw(_ handle: TerminalHandle, text: String) {
        // Raw PTY bytes — no Enter. Used by operator send_keys (CSI chords).
        (handle as? Handle)?.view.send(txt: text)
    }

    /// Exactly the visible viewport (rows × cols), matching what the human sees —
    /// `getLine(row:)` is already relative to `yDisp`. Right-trim each row so we do not
    /// pad with trailing spaces out to the column width.
    func captureVisibleText(_ handle: TerminalHandle) -> String? {
        guard let view = (handle as? Handle)?.view else { return nil }
        let terminal = view.getTerminal()
        let rows = terminal.rows
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            guard let line = terminal.getLine(row: row) else {
                lines.append("")
                continue
            }
            lines.append(line.translateToString(trimRight: true))
        }
        // Drop only trailing blank rows so a half-empty screen is not a wall of empties,
        // but keep interior blanks (they are part of the layout).
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Submit with a pause before the carriage return so claude's TUI ingests the
    /// paste before the Enter (matching the Python bridge's 0.15s inject).
    func submit(_ handle: TerminalHandle, text: String) {
        send(handle, text: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.send(handle, text: "\r")
        }
    }

    /// The pasted part goes inside bracketed-paste markers while the program has that mode on
    /// (claude does), so claude reads it as one paste however the PTY slices the bytes.
    func submit(_ handle: TerminalHandle, prompt: TerminalPrompt) {
        let pastes = (handle as? Handle)?.view.getTerminal().bracketedPasteMode == true
        submit(handle, text: pastes ? prompt.bracketed : prompt.text)
    }

    /// Terminate the child and release the handle. Signals the child's whole process
    /// group (spawned via setsid, so pgid == pid) so claude's node/MCP grandchildren are
    /// reaped too, not just the top-level shell. The `pid > 1` guard is load-bearing:
    /// `kill(-0, …)` / `kill(-1, …)` would signal our own process group instead.
    func terminate(_ handle: TerminalHandle) {
        guard let h = handle as? Handle else { return }
        if let pid = h.pid, pid > 1 { kill(-pid, SIGTERM) }
        handles[ObjectIdentifier(h)] = nil
    }

    /// Tap the emulator's replies to the host (terminal → app), for headless probes that
    /// query the terminal over its own escape-sequence surface. See `-probePalette`.
    func captureResponses(_ handle: TerminalHandle, _ sink: @escaping (ArraySlice<UInt8>) -> Void) {
        (handle as? Handle)?.onSend = sink
    }

    /// The live terminal view for a handle (for SwiftUI embedding).
    func view(for handle: TerminalHandle?) -> LocalProcessTerminalView? {
        (handle as? Handle)?.view
    }
}

extension TerminalLink {
    /// The one place a clicked link (terminal or chat) reaches the system: a web link or an
    /// inert file opens, a runnable file is only revealed in Finder, anything else beeps.
    /// Not actor-bound: SwiftTerm calls `requestOpenLink` from a nonisolated delegate method.
    func perform() {
        switch self {
        case .web(let url), .file(let url): NSWorkspace.shared.open(url)
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .none: NSSound.beep()
        }
    }
}
