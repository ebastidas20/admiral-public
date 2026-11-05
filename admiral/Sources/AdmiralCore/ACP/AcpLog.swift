import Darwin
import Foundation

/// One ACP tab's log, `<base>/acp/<session>.log`: the agent's stderr, the connection's
/// non-protocol lines, and Admiral's own notes (a failed handshake, input that never went out).
///
/// Every writer opens it `O_APPEND`, the agent's stderr included, so lines from the process and
/// from Admiral land at the end instead of overwriting each other at stale offsets.
public enum AcpLog {
    public static func url(base: URL, session: String) -> URL {
        base.appendingPathComponent("acp", isDirectory: true).appendingPathComponent("\(session).log")
    }

    /// An append-only descriptor on `url`, creating the file (and its folder) first. -1 on failure.
    static func openAppending(_ url: URL) -> Int32 {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
    }

    /// The log's size now — where a launch starts, so `lastAgentLine(after:)` reads only its lines.
    public static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// How much of the log's end `lastAgentLine` reads, and how long a line it hands back: the
    /// line is shown in the UI (`connectError`), so neither a chatty agent nor one huge stderr
    /// line may make that read, or that label, unbounded.
    static let tailBytes: UInt64 = 8 * 1024
    public static let maxLineLength = 300

    /// How `JSONRPCConnection` logs a stdout line that is not JSON-RPC. That line is the agent's
    /// own words too: a launch command that enters another environment may write its failure there
    /// ("executable file not found in $PATH") to stdout, not stderr, so `lastAgentLine` counts it.
    public static let nonJSONPrefix = "acp: non-JSON line: "

    /// The line `ProcessAcpTransport` logs when the agent's process ends.
    static func exitLine(signal: Bool, status: Int32) -> String {
        "acp: agent \(signal ? "signal" : "exit") status \(status)"
    }

    /// The agent's exit status from this launch's stretch of the log (after `offset`), nil when
    /// it has not exited, or was killed by a signal.
    public static func exitStatus(_ url: URL, after offset: UInt64) -> Int32? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = size(url)
        let start = max(offset, end > tailBytes ? end - tailBytes : 0)
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let marker = "acp: agent exit status "
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .last { $0.hasPrefix(marker) || $0.hasPrefix("acp: agent signal status ") }
            .flatMap { $0.hasPrefix(marker) ? Int32($0.dropFirst(marker.count)) : nil }
    }

    /// Why a launch failed, as the UI shows it (Test connection, a tab's `connectError`):
    /// `reason`, the agent's last line from this launch, and — on exit 127 from `env` itself,
    /// which is a command not found on the `PATH` — a hint to give its full path.
    public static func failureReason(
        _ reason: String, log url: URL, after offset: UInt64, command: String
    ) -> String {
        let line = lastAgentLine(url, after: offset)
        var text = line.map { "\(reason): \($0)" } ?? reason
        // A 127 can come from inside the environment the launch command enters (its own missing
        // binary), which is not about this Mac's PATH: only `env`'s own complaint, or no word
        // at all, gets the hint — the command exists on this Mac's PATH, or inside that environment.
        if exitStatus(url, after: offset) == 127, line.map({ $0.hasPrefix("env:") }) ?? true {
            let name = (command as NSString).lastPathComponent
            text += " \u{2014} is `\(command)` on your PATH? Use its full path (e.g. /usr/local/bin/\(name))"
        }
        return text
    }

    /// The last line the agent itself wrote after `offset` — its stderr, or a non-JSON line on
    /// its stdout: the real reason a container or binary refused to start. Admiral's own lines
    /// carry an `acp:` prefix and are skipped (a non-JSON line is unwrapped from its prefix).
    /// Only the last `tailBytes` are read, and the line is cut at `maxLineLength`.
    public static func lastAgentLine(_ url: URL, after offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = size(url)
        let start = max(offset, end > tailBytes ? end - tailBytes : 0)
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let l = line.trimmingCharacters(in: .whitespaces)
                return l.hasPrefix(nonJSONPrefix)
                    ? String(l.dropFirst(nonJSONPrefix.count)).trimmingCharacters(in: .whitespaces) : l
            }
        func agentLine(_ l: String) -> Bool { !l.isEmpty && !l.hasPrefix("acp:") }
        // A read that starts mid-file starts mid-line: that first fragment is only the end of
        // a line, used only when no whole line follows it (one stderr line longer than the tail)
        // — and only when that line is the agent's: its start, before the read, decides.
        let whole = start > offset ? lines.dropFirst() : lines[...]
        let fragment = start > offset ? lines.first.flatMap { agentLine($0) ? $0 : nil } : nil
        guard let line = whole.last(where: agentLine)
            ?? fragment.flatMap({ lineIsAdmirals(handle, containing: start, after: offset) ? nil : $0 })
        else { return nil }
        return line.count > maxLineLength ? String(line.prefix(maxLineLength - 1)) + "\u{2026}" : line
    }

    /// Whether the line holding byte `position` starts with Admiral's `acp:` prefix, found by
    /// scanning back for its newline (not before `offset`, the launch's first byte). Admiral's
    /// traced lines are capped (`JSONRPCConnection.traceLimit`), so a line whose start is further
    /// back than `lookBack` is the agent's.
    private static func lineIsAdmirals(
        _ handle: FileHandle, containing position: UInt64, after offset: UInt64
    ) -> Bool {
        let lookBack: UInt64 = 16 * 1024
        let from = max(offset, position > lookBack ? position - lookBack : 0)
        // Up to `position`, plus the prefix's length past it: a line may start just before it.
        guard (try? handle.seek(toOffset: from)) != nil,
              let data = try? handle.read(upToCount: Int(position - from) + 4) else { return false }
        let before = data.prefix(Int(position - from))
        let lineStart: Data.Index
        if let newline = before.lastIndex(of: UInt8(ascii: "\n")) {
            lineStart = data.index(after: newline)
        } else if from == offset {
            lineStart = data.startIndex
        } else {
            return false
        }
        return data[lineStart...].starts(with: Data("acp:".utf8))
    }

    /// The log's last `maxBytes`, from the first whole line in them — what the ACP log view
    /// shows. Empty when there is no log yet.
    public static func tail(_ url: URL, maxBytes: UInt64 = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = size(url)
        let start = end > maxBytes ? end - maxBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        guard start > 0, let newline = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: newline)...])
    }

    /// Appends one line. Best effort: a log that cannot be written never takes a tab down.
    public static func append(_ line: String, to url: URL) {
        let fd = openAppending(url)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        let bytes = Array((line.hasSuffix("\n") ? line : line + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
