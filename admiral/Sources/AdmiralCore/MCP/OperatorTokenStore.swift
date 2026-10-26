import CryptoKit
import Foundation

/// Persistent bearer token for the operator MCP HTTP surface (`POST /mcp`,
/// `/sessions/<callsign>/events`).
///
/// END STATE: the token lives **only** in the Keychain (service `com.pedro.admiral.operator-mcp`,
/// account `token`). No token file is ever written. The one exception is the legacy plaintext
/// file from before the Keychain work, which `migrateLegacyTokenFile` moves into the Keychain at
/// startup and then deletes (see the table there). Everything about that file lives in that one
/// function plus `legacyTokenFile`/`fileToken` so the whole thing can be deleted later.
///
/// Resolution (`resolve`) first moves the item out of the login keychain when the build has a
/// keychain access group (`moveFromLoginKeychain`; a failed move resolves to "no token yet" —
/// never a mint), then:
///
/// | legacy file | Keychain            | result                                                   |
/// |-------------|---------------------|----------------------------------------------------------|
/// | exists      | anything            | `migrateLegacyTokenFile`: the FILE value wins (below)    |
/// | missing     | well-formed         | serve the Keychain value                                 |
/// | missing     | missing / malformed | FIRST RUN (no `operator-token-issued` marker): mint a    |
/// |             |                     | token, store it in the Keychain **only**. Marker present: |
/// |             |                     | never mint — status `.tokenLost`, Rotate issues a new one |
/// | missing     | timeout / error     | no token yet (`""`); the caller serves an in-memory one  |
///
/// All Keychain access goes through mirrors that callers bound with `GuardedOperatorTokenMirror`;
/// every function here is synchronous and must run off the main thread whenever a mirror can
/// block. Two mirrors are taken: `mirror` (short wait) for steady-state reads, and `patient`
/// (default: the same mirror) for first-run / migration calls, which may sit behind a Keychain
/// access prompt a human has to answer (`patientTimeout`). Token values are never logged.
public enum OperatorTokenStore {
    /// Legacy plaintext token file name (Application Support/Admiral). Migration-only.
    public static let fileName = "operator-mcp-token.txt"
    /// Session token passed into `MCPServer` for operator calls (not a real station).
    public static let mcpSessionToken = "admiral-operator"
    /// Steady-state Keychain reads: a short bound so a pending prompt never stalls anything.
    public static let steadyTimeout: TimeInterval = 2
    /// First-run / migration Keychain calls (run in the background): long enough for a human to
    /// answer an access prompt. The server keeps serving the file value meanwhile.
    public static let patientTimeout: TimeInterval = 120

    /// `token` is the value to serve; `""` means "no value to serve yet" and callers keep what
    /// they have. `mirror` is the Keychain status shown in Settings.
    public struct Resolution: Equatable, Sendable {
        public let token: String
        public let mirror: OperatorTokenMirrorStatus
        public init(token: String, mirror: OperatorTokenMirrorStatus) {
            self.token = token
            self.mirror = mirror
        }
    }

    public static func legacyTokenFile(base: URL) -> URL {
        base.appendingPathComponent(fileName)
    }

    /// `adm_` + 32 lowercase hex characters — what `mint()` produces.
    public static func isWellFormed(_ value: String) -> Bool {
        guard value.hasPrefix("adm_"), value.utf8.count == 36 else { return false }
        return value.dropFirst(4).utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// `adm_` + 32 lowercase hex characters.
    public static func mint() -> String {
        "adm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: - Resolution

    /// Load the effective token. Blocking when a mirror blocks — run off-main.
    public static func resolve(base: URL, mirror: OperatorTokenMirror?,
                               patient: OperatorTokenMirror? = nil) -> Resolution {
        let patient = patient ?? mirror
        // One-time, before anything reads: a build with a keychain access group takes the token
        // out of the login keychain (where builds without one keep it).
        var moveFailure: Error?
        do {
            if try patient?.moveFromLoginKeychain() == true { NSLog("OperatorTokenStore: token moved into the keychain access group") }
        } catch {
            noteFailure(error)
            moveFailure = error
        }
        if let migrated = migrateLegacyTokenFile(base: base, mirror: patient) { return migrated }
        // A failed move leaves the group empty while the token clients use is still in the login
        // keychain: reading on would mint over it. Report it; the retry / Recheck moves it later.
        if let moveFailure { return Resolution(token: "", mirror: status(for: moveFailure)) }
        switch readMirror(mirror) {
        case let .value(k) where isWellFormed(k):
            noteIssued(k, base: base)
            return Resolution(token: k, mirror: .inSync)
        case .value, .missing:
            // A token was issued before, so a missing one means the store lost it (another
            // build's keychain, a deleted item): minting would silently break every client that
            // holds the old copy. Only a first run mints without being asked.
            if wasIssued(base: base) {
                NSLog("OperatorTokenStore: Keychain has no token but one was issued before (%@); not minting — Rotate to issue a new one",
                      issuedHash(base: base) ?? "?")
                return Resolution(token: "", mirror: .tokenLost)
            }
            return storeMinted(patient, base: base, reason: "first run")
        case let .failed(timedOut):
            // Unknown Keychain state: never mint over what we could not read.
            return Resolution(token: "", mirror: timedOut ? .timedOut : .unavailable)
        }
    }

    /// Rotate: a fresh token into the Keychain ONLY (verified by read-back). On any failure
    /// nothing changes (`token == ""`). A legacy file, if one still exists, is superseded.
    public static func rotateToken(base: URL, mirror: OperatorTokenMirror?) -> Resolution {
        let r = storeMinted(mirror, base: base, reason: "Rotate pressed")
        guard !r.token.isEmpty else { return r }
        supersedeLegacyFile(base: base, with: r.token, mirror: mirror)
        return r
    }

    // MARK: - Legacy file migration (DELETE THIS SECTION once no install has the file any more)

    /// The trimmed, non-empty legacy file value, or nil. Tightens the file to 0600 as a side effect.
    public static func fileToken(base: URL) -> String? {
        let url = legacyTokenFile(base: base)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        restrictPermissions(url)
        return trimmed
    }

    /// LEGACY MIGRATION (temporary). Returns `nil` when there is no legacy file; otherwise the
    /// value to serve (always the FILE value — the one clients use) and the Keychain status.
    /// END STATE: the Keychain holds the file value, verified by an in-process read-back, and
    /// the file is gone.
    ///
    /// - Keychain equals the file value → delete the file (nothing written).
    /// - Keychain missing, malformed, DIFFERENT, or unreadable for a reason other than a timeout
    ///   → the file value overwrites it (`mirror.replace`: update in place, falling back to
    ///   delete + add when this build may not update the old item), is read back in-process, and
    ///   only if the read-back equals the file value is the file deleted.
    /// - Timeout (an unanswered access prompt) → keep the file, serve it, status `timedOut`; the
    ///   caller retries (see `OperatorTokenRetryPolicy`) and the Recheck button re-runs it.
    /// - Write error / read-back mismatch → keep the file, serve it.
    ///
    /// The file is deleted ONLY by `removeLegacyFile`, which re-checks equality in-process.
    public static func migrateLegacyTokenFile(base: URL, mirror: OperatorTokenMirror?) -> Resolution? {
        guard let f = fileToken(base: base) else { return nil }
        func settle(_ k: String) -> Resolution {
            guard k == f else { return Resolution(token: f, mirror: .outOfSync) }
            noteIssued(f, base: base)
            removeLegacyFile(base: base, expected: f, verifiedKeychainValue: k)
            return Resolution(token: f, mirror: .inSync)
        }
        switch readMirror(mirror) {
        case let .failed(timedOut) where timedOut:
            return Resolution(token: f, mirror: .timedOut)
        case let .value(k) where k == f:
            return settle(k)
        case .value, .missing, .failed:  // missing / malformed / differing / denied: file wins
            guard let mirror else { return Resolution(token: f, mirror: .unavailable) }
            do { try mirror.replace(f) } catch {
                noteFailure(error)
                return Resolution(token: f, mirror: status(for: error))
            }
            switch readMirror(mirror) {  // read back in-process before any delete
            case let .value(k2): return settle(k2)
            case let .failed(timedOut): return Resolution(token: f, mirror: timedOut ? .timedOut : .unavailable)
            case .missing: return Resolution(token: f, mirror: .unavailable)
            }
        }
    }

    /// The only place the legacy file is deleted. Refuses unless the Keychain value that was just
    /// read in-process equals the expected value AND the file still holds that same value.
    private static func removeLegacyFile(base: URL, expected: String, verifiedKeychainValue: String) {
        guard verifiedKeychainValue == expected, fileToken(base: base) == expected else { return }
        do {
            try FileManager.default.removeItem(at: legacyTokenFile(base: base))
            NSLog("OperatorTokenStore: legacy token file removed (value verified in Keychain)")
        } catch {
            NSLog("OperatorTokenStore: could not remove legacy token file")
        }
    }

    /// After the Keychain was set to `value` (verified), make any legacy file agree and let the
    /// normal verified migration remove it — so the file is still never deleted unverified.
    private static func supersedeLegacyFile(base: URL, with value: String, mirror: OperatorTokenMirror?) {
        guard fileToken(base: base) != nil else { return }
        guard writeLegacyFile(value, base: base) else { return }
        _ = migrateLegacyTokenFile(base: base, mirror: mirror)
    }

    /// Atomic 0600 replace of the legacy file (only ever used to re-align it before deletion).
    private static func writeLegacyFile(_ token: String, base: URL) -> Bool {
        let fm = FileManager.default
        let url = legacyTokenFile(base: base)
        let tmp = base.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: Data(token.utf8),
                            attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            return false
        }
        return true
    }

    /// Owner read/write only. Non-fatal.
    static func restrictPermissions(_ url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue != 0o600 else { return }
        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("OperatorTokenStore: could not chmod token file to 0600")
        }
    }

    // MARK: - Internals

    private enum Read { case value(String), missing, failed(timedOut: Bool) }

    private static func readMirror(_ mirror: OperatorTokenMirror?) -> Read {
        guard let mirror else { return .failed(timedOut: false) }
        do {
            guard let raw = try mirror.read() else { return .missing }
            return .value(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            noteFailure(error)
            return .failed(timedOut: (error as? OperatorTokenMirrorError)?.isTimeout == true)
        }
    }

    /// Mint, write to the Keychain, and verify by reading back. `token == ""` on any failure.
    private static func storeMinted(_ mirror: OperatorTokenMirror?, base: URL, reason: String) -> Resolution {
        guard let mirror else { return Resolution(token: "", mirror: .unavailable) }
        let minted = mint()
        do { try mirror.write(minted) } catch {
            noteFailure(error)
            return Resolution(token: "", mirror: status(for: error))
        }
        switch readMirror(mirror) {
        case let .value(k) where k == minted:
            NSLog("OperatorTokenStore: new token issued (%@), id %@", reason, hashPrefix(minted))
            noteIssued(minted, base: base)
            return Resolution(token: minted, mirror: .inSync)
        case .value: return Resolution(token: "", mirror: .outOfSync)
        case let .failed(timedOut): return Resolution(token: "", mirror: timedOut ? .timedOut : .unavailable)
        case .missing: return Resolution(token: "", mirror: .unavailable)
        }
    }

    // MARK: - Issued marker

    /// Non-secret record that a token was issued for this support dir: the first 12 hex digits
    /// of its SHA-256. It outlives the Keychain item, which is the whole point.
    public static let issuedMarkerName = "operator-token-issued"

    static func issuedMarker(base: URL) -> URL { base.appendingPathComponent(issuedMarkerName) }

    static func hashPrefix(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func wasIssued(base: URL) -> Bool {
        FileManager.default.fileExists(atPath: issuedMarker(base: base).path)
    }

    static func issuedHash(base: URL) -> String? {
        (try? String(contentsOf: issuedMarker(base: base), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Record `token` as the issued one (also backfills an install that predates the marker).
    static func noteIssued(_ token: String, base: URL) {
        let hash = hashPrefix(token)
        guard issuedHash(base: base) != hash else { return }
        try? Data(hash.utf8).write(to: issuedMarker(base: base), options: .atomic)
    }

    private static func status(for error: Error) -> OperatorTokenMirrorStatus {
        (error as? OperatorTokenMirrorError)?.isTimeout == true ? .timedOut : .unavailable
    }

    private static func noteFailure(_ error: Error) {
        let e = error as? OperatorTokenMirrorError
        NSLog("OperatorTokenStore: Keychain %@ (status %d)",
              e?.isTimeout == true ? "timed out" : "unavailable", e?.status ?? -1)
    }
}
