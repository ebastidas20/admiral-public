import XCTest
@testable import AdmiralCore

/// An isolated instance's support dir is often too deep for a Unix socket address (104 bytes on
/// macOS): its bridge socket then never listened and every session's bridge MCP failed to
/// connect. The path is shortened instead, still one per instance.
final class AdmiralSocketPathTests: XCTestCase {
    private let deep = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-someone-code-project/0123456789abcdef-0123-4567-89ab/scratchpad/sup")

    func testAShortPathIsKept() {
        let dir = URL(fileURLWithPath: "/Users/u/Library/Application Support/Admiral")
        XCTAssertEqual(AdmiralPaths.socketPath("bridge-p.sock", in: dir), dir.path + "/bridge-p.sock")
    }

    func testATooLongPathBecomesAShortOneThatABoundSocketAccepts() throws {
        let path = AdmiralPaths.socketPath("bridge-routing-probe-82218.sock", in: deep)
        XCTAssertLessThanOrEqual(path.utf8.count, AdmiralPaths.maxSocketPathBytes)
        let server = LineSocketServer(path: path) { $0 }
        XCTAssertTrue(server.start(), "listens at \(path)")
        server.stop()
    }

    func testEachInstanceKeepsItsOwnSocketAndTheAnswerIsStable() {
        let a = AdmiralPaths.socketPath("bridge-a.sock", in: deep)
        XCTAssertNotEqual(a, AdmiralPaths.socketPath("bridge-b.sock", in: deep))
        XCTAssertNotEqual(a, AdmiralPaths.socketPath("bridge-a.sock", in: deep.appendingPathComponent("x")))
        XCTAssertEqual(a, AdmiralPaths.socketPath("bridge-a.sock", in: deep), "the app and its sessions agree")
    }
}
