import Foundation
import os
import AdmiralCore

/// Runs one `GroupRelevance.prompt` through a headless `claude -p` on haiku, on the user's own
/// login, and returns its raw answer. nil on any failure (spawn, timeout, non-zero exit), which
/// `GroupRelevance.select` treats as "no answer". Every failure is logged, with stderr, under
/// the `group-routing` category, so an untagged message that woke nobody can be traced:
/// `log show --predicate 'subsystem == "com.pedro.admiral" AND category == "group-routing"'`.
enum GroupRelevanceScorer {
    static let timeout: TimeInterval = 30
    static let log = Logger(subsystem: "com.pedro.admiral", category: "group-routing")

    static func route(prompt: String, claude: String) async -> String? {
        await Task.detached(priority: .utility) { run(prompt: prompt, claude: claude) }.value
    }

    private static func run(prompt: String, claude: String) -> String? {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--model", "haiku", "--no-session-persistence"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        // A claude started from inside a claude session skips its own transcript otherwise.
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CLAUDECODE") && !$0.key.hasPrefix("CLAUDE_CODE_") && $0.key != "ADMIRAL_SESSION"
        }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            log.error("router spawn failed (\(claude, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Both pipes are drained while claude runs: a full pipe would block it until the timeout.
        let reads = DispatchGroup()
        var out = Data(), err = Data()
        DispatchQueue.global(qos: .utility).async(group: reads) { out = output.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global(qos: .utility).async(group: reads) { err = errors.fileHandleForReading.readDataToEndOfFile() }
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            log.error("router timed out after \(Int(timeout), privacy: .public)s")
            return nil
        }
        reads.wait()
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        let text = String(data: out, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderr = String(data: err, encoding: .utf8) ?? ""
            log.error("router exited \(process.terminationStatus, privacy: .public) in \(seconds, privacy: .public)s: \(stderr.prefix(500), privacy: .public)")
            return nil
        }
        log.info("router answered in \(seconds, privacy: .public)s: \(text.prefix(200), privacy: .public)")
        return text
    }
}
