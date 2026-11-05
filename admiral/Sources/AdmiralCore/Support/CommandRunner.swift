import Foundation

/// Runs a command and hands back its exit code and stdout. The seam that lets the git reads
/// behind the touched-repos log run where the files are: on this Mac (`LocalCommandRunner`) or
/// inside an ACP agent's environment (`ExecCommandRunner`, e.g. a container).
public protocol CommandRunner: Sendable {
    /// `nil` = the command could not be launched, or ran past `timeout` (and was terminated).
    /// `timeout: .infinity` waits as long as the command runs.
    func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)?
    /// The same run, with stderr kept — for a caller that reads it (gh's rate-limit and merge
    /// errors). A runner that cannot capture it hands back `""`.
    func runCapturingStderr(_ argv: [String], cwd: String?, timeout: TimeInterval) -> CommandOutput?
    /// The bound a caller with no opinion of its own (`Git`) uses for this runner.
    var defaultTimeout: TimeInterval { get }
}

/// One finished command: exit code, stdout and stderr, both read in full.
public struct CommandOutput: Sendable, Equatable {
    public let code: Int32
    public let stdout: String
    public let stderr: String

    public init(code: Int32, stdout: String, stderr: String) {
        self.code = code
        self.stdout = stdout
        self.stderr = stderr
    }
}

extension CommandRunner {
    /// Unbounded: a local command has always been waited out.
    public var defaultTimeout: TimeInterval { .infinity }

    public func runCapturingStderr(_ argv: [String], cwd: String?, timeout: TimeInterval) -> CommandOutput? {
        run(argv, cwd: cwd, timeout: timeout).map { CommandOutput(code: $0.code, stdout: $0.stdout, stderr: "") }
    }
}

/// `argv` through `/usr/bin/env` on this Mac — no shell, PATH lookup by `env`. Both pipes are
/// drained WHILE the process runs: a command that writes more than a pipe buffer (a `gh pr list`
/// with checks) would otherwise block on write, never exit, and run into the timeout.
public struct LocalCommandRunner: CommandRunner {
    /// The child's whole environment; nil = inherit Admiral's, as every local caller does.
    public let environment: [String: String]?

    public init(environment: [String: String]? = nil) {
        self.environment = environment
    }

    public func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)? {
        runCapturingStderr(argv, cwd: cwd, timeout: timeout).map { ($0.code, $0.stdout) }
    }

    public func runCapturingStderr(_ argv: [String], cwd: String?, timeout: TimeInterval) -> CommandOutput? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        if let environment { process.environment = environment }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        let stdout = PipeDrain(out), stderr = PipeDrain(err)
        let deadline: DispatchTime = timeout.isFinite ? .now() + timeout : .distantFuture
        guard exited.wait(timeout: deadline) == .success else {
            process.terminate()
            return nil
        }
        // A grandchild still holding a pipe open past the exit is bounded by the same deadline.
        guard let outData = stdout.wait(until: deadline), let errData = stderr.wait(until: deadline) else {
            return nil
        }
        return CommandOutput(code: process.terminationStatus,
                             stdout: String(data: outData, encoding: .utf8) ?? "",
                             stderr: String(decoding: errData, as: UTF8.self))
    }
}

/// Reads one pipe to EOF on its own thread, so the writer never blocks on a full buffer.
private final class PipeDrain: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    /// The pipe's bytes once it hits EOF; nil if `deadline` passes first.
    func wait(until deadline: DispatchTime) -> Data? {
        done.wait(timeout: deadline) == .success ? data : nil
    }
}

/// Runs `argv` inside an ACP agent's environment: `exec.command exec.args… argv…` (e.g.
/// `docker exec -w /workspace box git …`), launched on the Mac with no shell. A `cwd` is a path
/// in THAT environment, so it is applied there, by a `sh` the prefix runs:
/// `sh -c 'cd <cwd> && exec "$@"' sh argv…` — the cwd single-quoted, the argv untouched.
///
/// The prefix is found on the same `PATH` the agent is launched with (`LaunchEnvironment`),
/// decided per run so a login-shell `PATH` that resolves after the tab opened is picked up.
public struct ExecCommandRunner: CommandRunner {
    public let exec: AcpCommand
    /// A hung `docker exec` (a stopped container, a wedged daemon) must not pin a thread forever.
    public let defaultTimeout: TimeInterval
    /// The agent config's own `PATH`, which wins over the login shell's.
    public let configuredPath: String?
    private let baseEnvironment: [String: String]
    private let loginPath: @Sendable () -> String?

    public init(
        exec: AcpCommand,
        defaultTimeout: TimeInterval = 5,
        configuredPath: String? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        loginPath: @escaping @Sendable () -> String? = { LoginShellPath.shared.current() }
    ) {
        self.exec = exec
        self.defaultTimeout = defaultTimeout
        self.configuredPath = configuredPath
        self.baseEnvironment = baseEnvironment
        self.loginPath = loginPath
    }

    /// The environment `exec` is launched with.
    public var environment: [String: String] {
        LaunchEnvironment.make(
            base: baseEnvironment, overrides: configuredPath.map { ["PATH": $0] } ?? [:], loginPath: loginPath)
    }

    private var local: LocalCommandRunner { LocalCommandRunner(environment: environment) }

    public func argv(for argv: [String], cwd: String?) -> [String] {
        let prefix = [exec.command] + exec.args
        guard let cwd else { return prefix + argv }
        return prefix + ["sh", "-c", "cd \(ShellQuote.single(cwd)) && exec \"$@\"", "sh"] + argv
    }

    public func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)? {
        local.run(self.argv(for: argv, cwd: cwd), cwd: nil, timeout: timeout)
    }

    public func runCapturingStderr(_ argv: [String], cwd: String?, timeout: TimeInterval) -> CommandOutput? {
        local.runCapturingStderr(self.argv(for: argv, cwd: cwd), cwd: nil, timeout: timeout)
    }
}
