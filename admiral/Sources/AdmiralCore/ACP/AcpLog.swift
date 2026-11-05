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

    /// The last line the agent itself wrote (its stderr) after `offset`: the real reason a
    /// container or binary refused to start. Admiral's own lines carry an `acp:` prefix and are
    /// skipped. Only the last `tailBytes` are read, and the line is cut at `maxLineLength`.
    public static func lastAgentLine(_ url: URL, after offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = size(url)
        let start = max(offset, end > tailBytes ? end - tailBytes : 0)
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func agentLine(_ l: String) -> Bool { !l.isEmpty && !l.hasPrefix("acp:") }
        // A read that starts mid-file starts mid-line: that first fragment is only the end of
        // a line, used only when no whole line follows it (one stderr line longer than the tail).
        let whole = start > offset ? lines.dropFirst() : lines[...]
        guard let line = whole.last(where: agentLine) ?? lines.first.flatMap({ agentLine($0) ? $0 : nil })
        else { return nil }
        return line.count > maxLineLength ? String(line.prefix(maxLineLength - 1)) + "\u{2026}" : line
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
