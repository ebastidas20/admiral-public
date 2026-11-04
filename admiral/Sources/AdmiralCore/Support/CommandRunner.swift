import Foundation

/// Runs a command and hands back its exit code and stdout. The seam that lets the git reads
/// behind the touched-repos log run where the files are: on this Mac (`LocalCommandRunner`) or
/// inside an ACP agent's environment (`ExecCommandRunner`, e.g. a container).
public protocol CommandRunner: Sendable {
    /// `nil` = the command could not be launched, or ran past `timeout` (and was terminated).
    /// `timeout: .infinity` waits as long as the command runs.
    func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)?
}

/// `argv` through `/usr/bin/env` on this Mac — no shell, PATH lookup by `env`, stderr
/// discarded, stdout read once the process exits. This is what `Git` always did.
public struct LocalCommandRunner: CommandRunner {
    public init() {}

    public func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        if timeout.isFinite {
            guard exited.wait(timeout: .now() + timeout) == .success else {
                process.terminate()
                return nil
            }
        } else {
            exited.wait()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Runs `argv` inside an ACP agent's environment: `exec.command exec.args… argv…` (e.g.
/// `docker exec -w /workspace box git …`), launched on the Mac with no shell. A `cwd` is a path
/// in THAT environment, so it is applied there, by a `sh` the prefix runs:
/// `sh -c 'cd <cwd> && exec "$@"' sh argv…` — the cwd single-quoted, the argv untouched.
public struct ExecCommandRunner: CommandRunner {
    public let exec: AcpCommand

    public init(exec: AcpCommand) { self.exec = exec }

    public func argv(for argv: [String], cwd: String?) -> [String] {
        let prefix = [exec.command] + exec.args
        guard let cwd else { return prefix + argv }
        return prefix + ["sh", "-c", "cd \(ShellQuote.single(cwd)) && exec \"$@\"", "sh"] + argv
    }

    public func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)? {
        LocalCommandRunner().run(self.argv(for: argv, cwd: cwd), cwd: nil, timeout: timeout)
    }
}
