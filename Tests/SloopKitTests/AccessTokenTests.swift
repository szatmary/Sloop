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

    func testParsesExpiryAndAudienceArray() throws {
        let exp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let raw = jwt(["exp": exp, "aud": ["abc123", "def456"]])
        let token = try XCTUnwrap(AccessToken(raw: raw))
        XCTAssertEqual(token.expiresAt.timeIntervalSince1970, exp, accuracy: 1)
        XCTAssertEqual(token.audiences, ["abc123", "def456"])
        XCTAssertFalse(token.isExpired)
        XCTAssertEqual(token.raw, raw)
    }

    func testParsesSingleStringAudience() throws {
        let raw = jwt(["exp": Date().addingTimeInterval(600).timeIntervalSince1970,
                       "aud": "solo"])
        XCTAssertEqual(AccessToken(raw: raw)?.audiences, ["solo"])
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

    /// `aud` is either a JSON array or a bare string (RFC 7519) — never an
    /// object. A malformed/attacker-adjacent payload carrying one must fail
    /// closed rather than crash the decoder.
    func testAudAsObjectIsNil() {
        let raw = jwt(["exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
                       "aud": ["nested": "object"]])
        XCTAssertNil(AccessToken(raw: raw))
    }

    /// `aud` explicitly present but `null` must decode safely to an empty
    /// audience list, not crash or wedge the optional's decoding.
    func testAudAsNullYieldsEmptyAudiences() throws {
        let raw = jwt(["exp": Date().addingTimeInterval(3600).timeIntervalSince1970,
                       "aud": NSNull()])
        let token = try XCTUnwrap(AccessToken(raw: raw))
        XCTAssertEqual(token.audiences, [])
        XCTAssertFalse(token.isExpired)
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
