import Darwin
import Foundation

/// The byte pipe to one ACP agent: ndjson lines in, ndjson lines out.
public protocol AcpTransport: AnyObject, Sendable {
    /// Lines from the agent's stdout (no trailing newline). Finishes on EOF / process exit.
    var lines: AsyncStream<String> { get }
    func send(line: String) throws
    func terminate()
}

public struct AcpTransportError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// Launches an agent command directly (no shell) and speaks ndjson over its stdio.
/// The agent's stderr is appended to `logURL`.
public final class ProcessAcpTransport: AcpTransport, @unchecked Sendable {
    public let lines: AsyncStream<String>
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrHandle: FileHandle
    private let writeLock = NSLock()
    private var stdinClosed = false

    public init(command: AcpCommand, env: [String: String], logURL: URL) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) {
            guard fm.createFile(atPath: logURL.path, contents: nil) else {
                throw AcpTransportError(description: "cannot create log file \(logURL.path)")
            }
        }
        stderrHandle = try FileHandle(forWritingTo: logURL)
        try stderrHandle.seekToEnd()

        var continuation: AsyncStream<String>.Continuation!
        lines = AsyncStream { continuation = $0 }
        let cont = continuation!

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command.command] + command.args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrHandle

        // Parent-side ends must not leak into any other child; stdin writes must not raise SIGPIPE.
        for fh in [stdinPipe.fileHandleForWriting, stdoutPipe.fileHandleForReading] {
            _ = fcntl(fh.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let reader = LineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                if let rest = reader.flush() { cont.yield(rest) }
                cont.finish()
                return
            }
            for line in reader.append(data) { cont.yield(line) }
        }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            cont.finish()
            try? stderrHandle.close()
            throw error
        }
        // Child holds its own copies now.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrHandle.close()
    }

    public func send(line: String) throws {
        var bytes = Array((line + "\n").utf8)
        try writeLock.withLock {
            guard !stdinClosed else { throw AcpTransportError(description: "transport closed") }
            let fd = stdinPipe.fileHandleForWriting.fileDescriptor
            while !bytes.isEmpty {
                let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AcpTransportError(description: "write failed: errno \(errno)")
                }
                bytes.removeFirst(n)
            }
        }
    }

    public func terminate() {
        writeLock.withLock {
            if !stdinClosed {
                stdinClosed = true
                try? stdinPipe.fileHandleForWriting.close()
            }
        }
        if process.isRunning { process.terminate() }
    }

    /// Splits a byte stream into `\n`-terminated lines (tolerating `\r\n`).
    private final class LineBuffer: @unchecked Sendable {
        private var buffer = Data()

        func append(_ data: Data) -> [String] {
            buffer.append(data)
            var out: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(Self.string(buffer[buffer.startIndex..<nl]))
                buffer = Data(buffer[buffer.index(after: nl)...])
            }
            return out
        }

        func flush() -> String? {
            defer { buffer = Data() }
            return buffer.isEmpty ? nil : Self.string(buffer)
        }

        private static func string(_ d: Data) -> String {
            var s = String(decoding: d, as: UTF8.self)
            if s.hasSuffix("\r") { s.removeLast() }
            return s
        }
    }
}
