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

    /// The last line the agent itself wrote (its stderr) after `offset`: the real reason a
    /// container or binary refused to start. Admiral's own lines carry an `acp:` prefix and are skipped.
    public static func lastAgentLine(_ url: URL, after offset: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !$0.hasPrefix("acp:") }
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
