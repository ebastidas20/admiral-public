import XCTest
@testable import AdmiralCore

/// In-memory stand-in for the Keychain — tests never touch the real Keychain.
final class FakeMirror: OperatorTokenMirror, @unchecked Sendable {
    var value: String?
    var failReads = false
    var failWrites = false
    var readDelay: TimeInterval = 0
    /// Simulates a Keychain that accepts a write but reads back something else.
    var readbackOverride: String?
    var writes = 0
    /// Simulates an item owned by another build: in-place updates fail with an ACL error, but
    /// delete + add (what `replace` falls back to) works.
    var updateDeniedByACL = false
    var deleteAndAdds = 0
    /// The login-keychain item a build with an access group moves in before its first read
    /// (`moveFromLoginKeychain`); nil = nothing to move.
    var loginKeychainValue: String?
    var failMove = false
    var moveDelay: TimeInterval = 0
    var moves = 0
    func moveFromLoginKeychain() throws -> Bool {
        moves += 1
        if moveDelay > 0 { Thread.sleep(forTimeInterval: moveDelay) }
        if failMove { throw OperatorTokenMirrorError(status: -25308) }
        guard let moved = loginKeychainValue, value == nil else { return false }
        value = moved
        loginKeychainValue = nil
        return true
    }
    /// Delay applied to the first read only (a Keychain prompt that is answered eventually).
    var firstReadDelay: TimeInterval = 0
    private var reads = 0
    func read() throws -> String? {
        reads += 1
        if reads == 1, firstReadDelay > 0 { Thread.sleep(forTimeInterval: firstReadDelay) }
        if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
        if failReads { throw OperatorTokenMirrorError(status: -25293) }
        if writes > 0, let o = readbackOverride { return o }
        return value
    }
    func write(_ v: String) throws {
        if failWrites { throw OperatorTokenMirrorError(status: -25308) }
        if updateDeniedByACL, value != nil { throw OperatorTokenMirrorError(status: -25293) }
        writes += 1
        value = v
    }
    func replace(_ v: String) throws {
        if failWrites { throw OperatorTokenMirrorError(status: -25308) }
        if updateDeniedByACL, value != nil {
            deleteAndAdds += 1
            value = nil
            updateDeniedByACL = false  // the fresh item is owned by this build
        }
        writes += 1
        value = v
    }
}

final class OperatorTokenMirrorTests: XCTestCase {
    private var dir: URL!
    private let a = "adm_" + String(repeating: "a", count: 32)
    private let b = "adm_" + String(repeating: "b", count: 32)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-op-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private var legacy: URL { OperatorTokenStore.legacyTokenFile(base: dir) }
    private var legacyExists: Bool { FileManager.default.fileExists(atPath: legacy.path) }
    private func writeLegacy(_ v: String) throws {
        try v.write(to: legacy, atomically: true, encoding: .utf8)
    }
    /// The token files in the dir. The non-secret issued marker (a hash prefix) is expected and
    /// is not a token file, so it is left out.
    private var dirListing: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 != OperatorTokenStore.issuedMarkerName }.sorted()
    }

    func testWellFormed() {
        XCTAssertTrue(OperatorTokenStore.isWellFormed(a))
        XCTAssertFalse(OperatorTokenStore.isWellFormed("adm_" + String(repeating: "A", count: 32)))
        XCTAssertFalse(OperatorTokenStore.isWellFormed("adm_" + String(repeating: "a", count: 31)))
        XCTAssertFalse(OperatorTokenStore.isWellFormed("adm_" + String(repeating: "g", count: 32)))
        XCTAssertFalse(OperatorTokenStore.isWellFormed("tok_" + String(repeating: "a", count: 32)))
        XCTAssertFalse(OperatorTokenStore.isWellFormed(""))
        XCTAssertTrue(OperatorTokenStore.isWellFormed(OperatorTokenStore.mint()))
    }

    // MARK: no legacy file — Keychain only

    func testKeychainValueIsServedAndNoFileWritten() {
        let m = FakeMirror(); m.value = a
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: a, mirror: .inSync))
        XCTAssertEqual(m.writes, 0)
        XCTAssertEqual(dirListing, [])
    }

    func testMintGoesToKeychainOnlyAndNoFileIsWritten() {
        let m = FakeMirror()
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertTrue(OperatorTokenStore.isWellFormed(r.token))
        XCTAssertEqual(r.mirror, .inSync)
        XCTAssertEqual(m.value, r.token)
        XCTAssertEqual(dirListing, [], "no token file (or temp file) may be created on mint")
        // Stable across launches.
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: m).token, r.token)
        XCTAssertEqual(m.writes, 1)
    }

    /// A build that just gained a keychain access group serves the token clients already use —
    /// moved out of the login keychain before the first read — never a fresh mint.
    func testTokenMovedFromTheLoginKeychainIsServedNotReminted() {
        let m = FakeMirror(); m.loginKeychainValue = a
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: a, mirror: .inSync))
        XCTAssertEqual(m.moves, 1)
        XCTAssertEqual(m.writes, 0, "nothing minted")
    }

    /// A failed move leaves the group empty while the token still sits in the login keychain:
    /// resolving must stop there instead of minting over it.
    func testFailedMoveMintsNothing() {
        let m = FakeMirror(); m.loginKeychainValue = a; m.failMove = true
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: m), .init(token: "", mirror: .unavailable))
        XCTAssertEqual(m.writes, 0)
        XCTAssertNil(m.value)
    }

    /// An unanswered prompt on the move times out like any patient call — retryable, no mint.
    func testTimedOutMoveIsRetryableAndMintsNothing() {
        let m = FakeMirror(); m.loginKeychainValue = a; m.moveDelay = 0.5
        let g = GuardedOperatorTokenMirror(wrapping: m, timeout: 0.1)
        let r = OperatorTokenStore.resolve(base: dir, mirror: g)
        XCTAssertEqual(r, .init(token: "", mirror: .timedOut))
        XCTAssertTrue(r.mirror.isRetryable)
        XCTAssertEqual(m.writes, 0)
    }

    func testGuardedMirrorForwardsTheMove() throws {
        let m = FakeMirror()
        let g = GuardedOperatorTokenMirror(wrapping: m, timeout: 1)
        _ = try g.moveFromLoginKeychain()
        _ = try g.waiting(upTo: 1).moveFromLoginKeychain()
        XCTAssertEqual(m.moves, 2)
    }

    func testMalformedKeychainValueWithoutFileIsReplacedByMint() {
        let m = FakeMirror(); m.value = "garbage"
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertTrue(OperatorTokenStore.isWellFormed(r.token))
        XCTAssertEqual(m.value, r.token)
        XCTAssertEqual(dirListing, [])
    }

    func testUnreadableKeychainWithoutFileMintsNothingAndNeverClobbers() {
        let m = FakeMirror(); m.value = b; m.failReads = true
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: "", mirror: .unavailable))
        XCTAssertEqual(m.writes, 0)
        XCTAssertEqual(m.value, b)
        XCTAssertEqual(dirListing, [])
    }

    func testMintWriteFailureReturnsNoTokenAndWritesNoFile() {
        let m = FakeMirror(); m.failWrites = true
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: m), .init(token: "", mirror: .unavailable))
        XCTAssertEqual(dirListing, [])
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: nil), .init(token: "", mirror: .unavailable))
    }

    // MARK: legacy migration (a)–(d)

    func testMigrationA_missingKeychain_writesVerifiesThenDeletesFile() throws {
        try writeLegacy(a + "\n")
        let m = FakeMirror()
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: a, mirror: .inSync))
        XCTAssertEqual(m.value, a)
        XCTAssertFalse(legacyExists)
        XCTAssertEqual(dirListing, [])
    }

    func testMigrationA_malformedKeychain_isReplacedByFileValueThenFileDeleted() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.value = "garbage"
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: a, mirror: .inSync))
        XCTAssertEqual(m.value, a)
        XCTAssertFalse(legacyExists)
    }

    func testMigrationA_readbackMismatchKeepsFile() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.readbackOverride = b
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: a, mirror: .outOfSync))
        XCTAssertTrue(legacyExists, "file must survive when the read-back does not equal it")
        XCTAssertEqual(OperatorTokenStore.fileToken(base: dir), a)
    }

    func testMigrationA_writeFailureKeepsFileAndServesIt() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.failWrites = true
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: m), .init(token: a, mirror: .unavailable))
        XCTAssertTrue(legacyExists)
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: nil), .init(token: a, mirror: .unavailable))
        XCTAssertTrue(legacyExists)
    }

    func testMigrationB_equalKeychain_deletesFileWithoutWriting() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.value = a
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: a, mirror: .inSync))
        XCTAssertEqual(m.writes, 0)
        XCTAssertFalse(legacyExists)
    }

    func testMigrationC_differingValues_fileWinsOverwritesKeychainThenDeletesFile() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.value = b
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: a, mirror: .inSync))
        XCTAssertEqual(m.value, a, "the FILE value (the one clients use) replaces the Keychain item")
        XCTAssertEqual(m.writes, 1)
        XCTAssertEqual(m.deleteAndAdds, 0, "updated in place when the ACL allows it")
        XCTAssertFalse(legacyExists)
        XCTAssertEqual(dirListing, [])
        // Settled: next launch just serves the Keychain value.
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: m), .init(token: a, mirror: .inSync))
    }

    func testMigrationC_differingValues_aclDeniesUpdate_fallsBackToDeleteAndAdd() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.value = b; m.updateDeniedByACL = true
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: a, mirror: .inSync))
        XCTAssertEqual(m.deleteAndAdds, 1)
        XCTAssertEqual(m.value, a)
        XCTAssertFalse(legacyExists)
    }

    func testMigrationC_differingValues_readbackMismatchKeepsFile() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.value = b; m.readbackOverride = b
        let r = OperatorTokenStore.resolve(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: a, mirror: .outOfSync))
        XCTAssertTrue(legacyExists, "the file is only deleted after an equal in-process read-back")
    }

    func testMigrationC_differingValues_writeFailureKeepsFileAndServesIt() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.value = b; m.failWrites = true
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: m), .init(token: a, mirror: .unavailable))
        XCTAssertTrue(legacyExists)
        XCTAssertEqual(m.value, b)
    }

    func testMigrationD_deniedReadStillLetsTheFileValueWin() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.value = b; m.failReads = true
        // The unreadable item is replaced (read-back then also fails → file kept, still served).
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: m), .init(token: a, mirror: .unavailable))
        XCTAssertTrue(legacyExists)
        XCTAssertEqual(m.value, a)
        // Retried later (Recheck / next launch): migration completes once reads work.
        m.failReads = false
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: m), .init(token: a, mirror: .inSync))
        XCTAssertFalse(legacyExists)
        XCTAssertEqual(m.value, a)
    }

    func testMigrationFunctionReturnsNilWithoutFile() {
        XCTAssertNil(OperatorTokenStore.migrateLegacyTokenFile(base: dir, mirror: FakeMirror()))
    }

    // MARK: timeouts / never blocks

    func testSlowKeychainTimesOutQuicklyAndFallsBackToFile() throws {
        try writeLegacy(a)
        let slow = FakeMirror(); slow.value = b; slow.readDelay = 5
        let guarded = GuardedOperatorTokenMirror(wrapping: slow, timeout: 0.3)
        let t0 = Date()
        let r = OperatorTokenStore.resolve(base: dir, mirror: guarded)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertEqual(r, .init(token: a, mirror: .timedOut))
        XCTAssertEqual(slow.writes, 0)
        XCTAssertTrue(legacyExists)
        // While the abandoned read is still stuck, further calls fail fast (no thread pile-up).
        let t1 = Date()
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: guarded),
                       .init(token: a, mirror: .timedOut))
        XCTAssertLessThan(Date().timeIntervalSince(t1), 0.2)
        XCTAssertEqual(OperatorTokenMirrorStatus.timedOut.label, "unavailable (timeout)")
    }

    func testTimeoutWithNoFileGivesNoTokenAndWritesNothing() {
        let slow = FakeMirror(); slow.value = b; slow.readDelay = 5
        let guarded = GuardedOperatorTokenMirror(wrapping: slow, timeout: 0.3)
        let t0 = Date()
        let r = OperatorTokenStore.resolve(base: dir, mirror: guarded)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
        XCTAssertEqual(r, .init(token: "", mirror: .timedOut))
        XCTAssertEqual(slow.value, b)
        XCTAssertEqual(dirListing, [])
    }

    func testPatientWaitCompletesMigrationWhereTheShortTimeoutGivesUp() throws {
        try writeLegacy(a)
        // A Keychain prompt a human answers after ~0.8 s: the short (steady) mirror gives up at
        // 0.2 s, the patient view of the SAME guarded mirror waits it out and finishes the job.
        let m = FakeMirror(); m.value = b; m.firstReadDelay = 0.8
        let guarded = GuardedOperatorTokenMirror(wrapping: m, timeout: 0.2)
        let r = OperatorTokenStore.resolve(base: dir, mirror: guarded,
                                           patient: guarded.waiting(upTo: 5))
        XCTAssertEqual(r, .init(token: a, mirror: .inSync))
        XCTAssertEqual(m.value, a)
        XCTAssertFalse(legacyExists)
    }

    func testSteadyStateReadKeepsTheShortTimeout() throws {
        let m = FakeMirror(); m.value = a; m.firstReadDelay = 1.5
        let guarded = GuardedOperatorTokenMirror(wrapping: m, timeout: 0.2)
        let t0 = Date()
        // No legacy file: the steady-state read uses the short mirror even when a patient one exists.
        let r = OperatorTokenStore.resolve(base: dir, mirror: guarded, patient: guarded.waiting(upTo: 5))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        XCTAssertEqual(r, .init(token: "", mirror: .timedOut))
        XCTAssertEqual(m.writes, 0)
    }

    func testTimedOutMigrationIsRetriedAfterThePromptIsAnswered() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.value = b; m.firstReadDelay = 0.6
        let guarded = GuardedOperatorTokenMirror(wrapping: m, timeout: 0.2)
        // First attempt: prompt still pending → file kept and served, status says timed out.
        let first = OperatorTokenStore.resolve(base: dir, mirror: guarded)
        XCTAssertEqual(first, .init(token: a, mirror: .timedOut))
        XCTAssertTrue(legacyExists)
        let policy = OperatorTokenRetryPolicy(interval: 0.1, maxAttempts: 20)
        XCTAssertTrue(policy.shouldRetry(status: first.mirror, attempt: 0))
        // The retry loop (what AppModel schedules): stuck calls fail fast until Allow lands.
        var attempt = 0
        var last = first
        let deadline = Date().addingTimeInterval(5)
        while policy.shouldRetry(status: last.mirror, attempt: attempt), Date() < deadline {
            Thread.sleep(forTimeInterval: policy.interval)
            attempt += 1
            last = OperatorTokenStore.resolve(base: dir, mirror: guarded)
        }
        XCTAssertEqual(last, .init(token: a, mirror: .inSync))
        XCTAssertGreaterThan(attempt, 0)
        XCTAssertEqual(m.value, a)
        XCTAssertFalse(legacyExists)
    }

    func testRetryPolicyOnlyRetriesTimeoutsAndStops() {
        let p = OperatorTokenRetryPolicy()
        XCTAssertEqual(p.interval, 15)
        XCTAssertEqual(p.maxAttempts, 20)  // ~5 minutes
        XCTAssertTrue(p.shouldRetry(status: .timedOut, attempt: 0))
        XCTAssertTrue(p.shouldRetry(status: .timedOut, attempt: 19))
        XCTAssertFalse(p.shouldRetry(status: .timedOut, attempt: 20))
        for st in [OperatorTokenMirrorStatus.inSync, .outOfSync, .unavailable, .checking] {
            XCTAssertFalse(p.shouldRetry(status: st, attempt: 0))
        }
        XCTAssertEqual(OperatorTokenStore.steadyTimeout, 2)
        XCTAssertEqual(OperatorTokenStore.patientTimeout, 120)
    }

    func testGuardedMirrorPassesThroughWhenFast() throws {
        let m = FakeMirror()
        let g = GuardedOperatorTokenMirror(wrapping: m, timeout: 1)
        XCTAssertNil(try g.read())
        try g.write(a)
        XCTAssertEqual(try g.read(), a)
    }

    // MARK: rotate

    func testRotateWritesKeychainOnly() throws {
        let m = FakeMirror()
        let first = OperatorTokenStore.resolve(base: dir, mirror: m).token
        let r = OperatorTokenStore.rotateToken(base: dir, mirror: m)
        XCTAssertNotEqual(r.token, first)
        XCTAssertTrue(OperatorTokenStore.isWellFormed(r.token))
        XCTAssertEqual(m.value, r.token)
        XCTAssertEqual(r.mirror, .inSync)
        XCTAssertEqual(dirListing, [], "rotate must not write a token file")
    }

    func testRotateWithBrokenKeychainChangesNothing() throws {
        let m = FakeMirror(); m.value = a; m.failWrites = true
        let r = OperatorTokenStore.rotateToken(base: dir, mirror: m)
        XCTAssertEqual(r, .init(token: "", mirror: .unavailable))
        XCTAssertEqual(m.value, a)
        XCTAssertEqual(dirListing, [])
    }

    func testRotateSupersedesAStaleLegacyFile() throws {
        try writeLegacy(a)
        let m = FakeMirror(); m.value = b
        let r = OperatorTokenStore.rotateToken(base: dir, mirror: m)
        XCTAssertEqual(m.value, r.token)
        XCTAssertFalse(legacyExists, "a stale file must not out-vote the rotated Keychain value at next launch")
        XCTAssertEqual(OperatorTokenStore.resolve(base: dir, mirror: m), .init(token: r.token, mirror: .inSync))
    }

    func testLabels() {
        XCTAssertEqual(OperatorTokenMirrorStatus.inSync.label, "in sync")
        XCTAssertEqual(OperatorTokenMirrorStatus.outOfSync.label, "out of sync (file value in use)")
    }

    // MARK: legacy file mode

    func testLegacyFileIsTightenedTo0600WhileItExists() throws {
        try writeLegacy(a)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legacy.path)
        _ = OperatorTokenStore.fileToken(base: dir)
        let attrs = try FileManager.default.attributesOfItem(atPath: legacy.path)
        XCTAssertEqual((attrs[.posixPermissions] as! NSNumber).intValue, 0o600)
    }
}
