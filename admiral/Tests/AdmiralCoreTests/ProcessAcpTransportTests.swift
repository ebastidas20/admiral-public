import XCTest
@testable import AdmiralCore

final class ProcessAcpTransportTests: XCTestCase {
    private func tempLog() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("acp-\(UUID().uuidString).log")
    }

    private func firstLine(_ t: ProcessAcpTransport, timeout: TimeInterval = 15) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                for await l in t.lines { return l }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let r = await group.next() ?? nil
            group.cancelAll()
            return r
        }
    }

    func testCatEchoesSentLine() async throws {
        let t = try ProcessAcpTransport(
            command: AcpCommand(command: "/bin/cat", args: []),
            env: [:],
            logURL: tempLog())
        defer { t.terminate() }
        try t.send(line: #"{"jsonrpc":"2.0","id":1}"#)
        let line = await firstLine(t)
        XCTAssertEqual(line, #"{"jsonrpc":"2.0","id":1}"#)
    }

    func testExitFinishesLinesAndStderrIsLogged() async throws {
        let log = tempLog()
        let t = try ProcessAcpTransport(
            command: AcpCommand(command: "/bin/sh", args: ["-c", "echo oops >&2; exit 3"]),
            env: [:],
            logURL: log)
        defer { t.terminate() }
        var count = 0
        for await _ in t.lines { count += 1 }
        XCTAssertEqual(count, 0)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("oops"))
    }

    func testEnvIsMergedOverProcessEnvironment() async throws {
        let t = try ProcessAcpTransport(
            command: AcpCommand(command: "/bin/sh", args: ["-c", "echo $ACP_TEST_VAR"]),
            env: ["ACP_TEST_VAR": "hello"],
            logURL: tempLog())
        defer { t.terminate() }
        let line = await firstLine(t)
        XCTAssertEqual(line, "hello")
    }
}
