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
