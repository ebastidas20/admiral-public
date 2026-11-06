import Foundation

/// A file path found in a chat message, resolved to something openable.
public struct ChatLink: Equatable, Sendable {
    /// Where it sits in the message, in characters.
    public let offset: Int
    public let length: Int
    /// The resolved file.
    public let url: URL
    /// The line it named (`ChatView.swift:52`), if any.
    public let line: Int?

    public init(offset: Int, length: Int, url: URL, line: Int? = nil) {
        self.offset = offset
        self.length = length
        self.url = url
        self.line = line
    }
}

/// Finds the file paths in a chat message so the view can make them clickable, the way
/// claude's own output is clickable in a terminal.
///
/// The filesystem is the filter: a token only becomes a link if the file is really there
/// (`TerminalLink`, the same resolution a clicked terminal link goes through, so a
/// workspace-relative path resolves against the session's cwd). That keeps prose like
/// "3.5" or "e.g." from turning blue, and it is why nothing here guesses at extensions.
public enum ChatLinks {
    /// Wrapping punctuation to peel off a token before testing it (markdown, prose, shell).
    static let wrappers = CharacterSet(charactersIn: "`'\"“”‘’(){}[]<>*_,;!?")

    public static func detect(in text: String, cwd: String,
                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [ChatLink] {
        guard !cwd.isEmpty else { return [] }
        var links: [ChatLink] = []
        var offset = 0
        for token in text.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace) {
            defer { offset += token.count + 1 }   // +1 for the separator
            guard token.count > 2 else { continue }

            // Peel leading wrappers, remembering how many came off so the highlighted range
            // still lands on the path itself.
            var candidate = Substring(token)
            var leading = 0
            while let first = candidate.unicodeScalars.first, wrappers.contains(first) {
                candidate = candidate.dropFirst(); leading += 1
            }
            // The tail is where prose piles up (`` `review.md`. ``, `notes.md:52).`): try the
            // token as written, then with trailing punctuation dropped a character at a time,
            // and keep the longest one that is really a file.
            for text in TerminalLink.proseCandidates(String(candidate)) {
                let (path, line) = splitLine(text)
                guard path.contains("/") || path.contains(".") else { continue }
                guard let url = TerminalLink.resolve(path, cwd: cwd, fileExists: fileExists).fileURL
                else { continue }
                links.append(ChatLink(offset: offset + leading, length: text.count, url: url, line: line))
                break
            }
        }
        return links
    }

    /// A code span that is exactly one http/https URL with a host → that URL; anything else nil.
    /// Foundation's markdown links a bare URL itself but never one inside backticks, which is
    /// how agents write URLs in tables.
    public static func codeSpanURL(_ span: String) -> URL? {
        let text = span.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// `path:52` / `path:52:7` → (path, 52). A Windows-style `C:` or a URL keeps its colon.
    static func splitLine(_ token: String) -> (String, Int?) {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let line = Int(parts[1]), line > 0, parts[0].count > 1 else {
            return (token, nil)
        }
        return (String(parts[0]), line)
    }
}
