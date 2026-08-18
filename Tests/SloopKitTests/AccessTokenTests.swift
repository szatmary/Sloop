// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class AccessTokenTests: XCTestCase {

    /// Build an unsigned JWT-shaped token with the given payload.
    private func jwt(_ payload: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(try! JSONSerialization.data(
            withJSONObject: ["alg": "RS256", "typ": "JWT"]))
        let body = b64url(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).fakesig"
    }

    func testParsesExpiry() throws {
        let exp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let raw = jwt(["exp": exp, "aud": ["abc123", "def456"]])
        let token = try XCTUnwrap(AccessToken(raw: raw))
        XCTAssertEqual(token.expiresAt.timeIntervalSince1970, exp, accuracy: 1)
        XCTAssertFalse(token.isExpired)
        XCTAssertEqual(token.raw, raw)
    }

    func testPastExpiryIsExpired() throws {
        let raw = jwt(["exp": Date().addingTimeInterval(-60).timeIntervalSince1970])
        XCTAssertEqual(AccessToken(raw: raw)?.isExpired, true)
    }

    func testNearExpiryCountsAsExpired() throws {   // 60 s skew guard
        let raw = jwt(["exp": Date().addingTimeInterval(30).timeIntervalSince1970])
        XCTAssertEqual(AccessToken(raw: raw)?.isExpired, true)
    }

    func testGarbageIsNil() {
        XCTAssertNil(AccessToken(raw: "not-a-jwt"))
        XCTAssertNil(AccessToken(raw: "a.b"))
        XCTAssertNil(AccessToken(raw: "a.%%%%.c"))
        XCTAssertNil(AccessToken(raw: jwt(["aud": "x"])))   // no exp claim
    }

    /// `exp` is documented (and everywhere else in this file) as a number.
    /// A payload that instead carries it as a string must fail closed — not
    /// coerce, not crash.
    func testExpAsStringIsNil() {
        let raw = jwt(["exp": "3000000000", "aud": "x"])
        XCTAssertNil(AccessToken(raw: raw))
    }

    /// Claims this app doesn't read must not cost the user a usable token,
    /// whatever shape they arrive in. `aud` used to be parsed — for nothing,
    /// since no production code ever looked at the result — and an `aud` the
    /// decoder didn't expect (an object where RFC 7519 allows an array or a
    /// bare string) failed the whole payload, discarding a token whose expiry
    /// was perfectly readable and which Cloudflare's edge, the only thing that
    /// actually validates audiences, might well have accepted.
    func testUnreadClaimsCannotInvalidateAToken() throws {
        let exp = Date().addingTimeInterval(3600).timeIntervalSince1970
        for aud in [["nested": "object"] as Any, NSNull(), 42, ["a", "b"]] {
            let token = try XCTUnwrap(AccessToken(raw: jwt(["exp": exp, "aud": aud])),
                                      "aud: \(aud)")
            XCTAssertFalse(token.isExpired)
        }
    }

    /// An extreme negative `exp` (deep past, but still a finite JSON number —
    /// the shape a corrupted or hostile payload might carry) must parse
    /// without crashing and read as expired.
    func testExtremeNegativeExpIsExpired() throws {
        let raw = jwt(["exp": -1e15])
        let token = try XCTUnwrap(AccessToken(raw: raw))
        XCTAssertTrue(token.isExpired)
    }

    /// An extreme positive `exp` must likewise parse without crashing, and
    /// read as not-expired.
    func testExtremePositiveExpIsNotExpired() throws {
        let raw = jwt(["exp": 1e15])
        let token = try XCTUnwrap(AccessToken(raw: raw))
        XCTAssertFalse(token.isExpired)
    }

    func testStoreValidTokenFiltersExpiredAndGarbage() throws {
        let store = InMemoryAccessTokenStore()
        XCTAssertNil(store.validToken(for: "ssh.example.com"))

        try store.setRawToken(jwt(["exp": Date().addingTimeInterval(-60).timeIntervalSince1970]),
                              for: "ssh.example.com")
        XCTAssertNil(store.validToken(for: "ssh.example.com"))

        try store.setRawToken("garbage", for: "ssh.example.com")
        XCTAssertNil(store.validToken(for: "ssh.example.com"))

        let good = jwt(["exp": Date().addingTimeInterval(3600).timeIntervalSince1970])
        try store.setRawToken(good, for: "ssh.example.com")
        XCTAssertEqual(store.validToken(for: "ssh.example.com")?.raw, good)

        try store.removeToken(for: "ssh.example.com")
        XCTAssertNil(store.validToken(for: "ssh.example.com"))
    }

    /// One store is shared by the whole app and it really is used from
    /// several threads: `HostListModel` reads and writes it on the main actor
    /// while `TokenClearingDialer` removes a rejected token from the SSH
    /// worker thread that was dialing. An unsynchronized Dictionary under
    /// that is undefined behaviour — this hammers it from every core at once,
    /// which crashes or hangs on a store without a lock (and is flagged
    /// outright by `swift test --sanitize=thread`), then checks it still
    /// works afterwards.
    func testConcurrentUseFromManyThreads() throws {
        let store = InMemoryAccessTokenStore()
        let good = jwt(["exp": Date().addingTimeInterval(3600).timeIntervalSince1970])

        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            let hostname = "ssh\(i % 8).example.com"
            switch i % 4 {
            case 0: try? store.setRawToken(good, for: hostname)
            case 1: _ = store.rawToken(for: hostname)
            case 2: _ = store.validToken(for: hostname)
            default: try? store.removeToken(for: hostname)
            }
        }

        try store.setRawToken(good, for: "after.example.com")
        XCTAssertEqual(store.validToken(for: "after.example.com")?.raw, good)
    }

    // MARK: shared tokens

    /// Two saved hosts behind one Access application share a token, because
    /// the token *is* that application's session. Deleting one of them used
    /// to remove it anyway, silently signing the user out of the other — an
    /// invisible side effect of deleting something unrelated.
    func testTokenIsStillNeededByAnotherHostOnTheSameAccessHostname() {
        let remaining = [
            SSHHost(alias: "staging", hostname: "ssh.example.com", username: "matt",
                    connectionMethod: .cloudflareAccess),
        ]
        XCTAssertTrue(accessTokenIsStillNeeded(for: "ssh.example.com", by: remaining))
    }

    /// Hostnames reach here in whatever case the user typed, so the check
    /// normalizes the same way the storage key does — otherwise "SSH.Example"
    /// and "ssh.example" look like different applications and the token is
    /// deleted out from under one of them.
    func testTokenNeedIsCaseInsensitive() {
        let remaining = [
            SSHHost(alias: "staging", hostname: "SSH.Example.COM", username: "matt",
                    connectionMethod: .cloudflareAccess),
        ]
        XCTAssertTrue(accessTokenIsStillNeeded(for: "ssh.example.com", by: remaining))
    }

    /// Nothing left that would use it: the token must go, since a bearer
    /// credential has no business outliving every host it was captured for.
    func testTokenIsNotNeededWhenNoAccessHostRemains() {
        XCTAssertFalse(accessTokenIsStillNeeded(for: "ssh.example.com", by: []))
        let unrelated = [
            SSHHost(alias: "other", hostname: "other.example.com", username: "matt",
                    connectionMethod: .cloudflareAccess),
        ]
        XCTAssertFalse(accessTokenIsStillNeeded(for: "ssh.example.com", by: unrelated))
    }

    /// A host that happens to share the hostname but doesn't go through
    /// Access has no use for the token and must not keep it alive.
    func testDirectHostOnTheSameHostnameDoesNotKeepTheToken() {
        let remaining = [
            SSHHost(alias: "direct", hostname: "ssh.example.com", username: "matt"),
        ]
        XCTAssertFalse(accessTokenIsStillNeeded(for: "ssh.example.com", by: remaining))
    }

    /// Hostnames are case-insensitive but reach the store in whatever case
    /// the user typed or an imported SSH config used, so the store must
    /// normalize the key: setting under one case and reading under another
    /// must resolve to the same entry.
    func testStoreKeyIsCaseInsensitive() throws {
        let store = InMemoryAccessTokenStore()
        let good = jwt(["exp": Date().addingTimeInterval(3600).timeIntervalSince1970])

        try store.setRawToken(good, for: "SSH.Example.com")
        XCTAssertEqual(store.validToken(for: "ssh.example.com")?.raw, good)
        XCTAssertEqual(store.validToken(for: "SSH.EXAMPLE.COM")?.raw, good)

        try store.removeToken(for: "ssh.EXAMPLE.com")
        XCTAssertNil(store.validToken(for: "SSH.Example.com"))
    }
}
