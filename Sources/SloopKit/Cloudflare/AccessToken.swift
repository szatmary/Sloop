// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A Cloudflare Access application token (`CF_Authorization` JWT). The app is
/// the bearer, not the verifier, so only the payload's `exp`/`aud` claims are
/// parsed (no signature check) — enough to know when a fresh browser login is
/// needed before we bother dialing.
public struct AccessToken: Equatable {
    public let raw: String
    public let expiresAt: Date
    public let audiences: [String]

    /// Treat tokens expiring within this window as already expired, so a
    /// connection doesn't start on a token that dies mid-handshake.
    private static let expirySkew: TimeInterval = 60

    public init?(raw: String) {
        let segments = raw.split(separator: ".")
        guard segments.count == 3,
              let payloadData = Self.base64urlDecode(String(segments[1])),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData)
        else { return nil }
        self.raw = raw
        self.expiresAt = Date(timeIntervalSince1970: payload.exp)
        self.audiences = payload.aud?.values ?? []
    }

    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-Self.expirySkew)
    }

    /// The one predicate every consumer of a raw `CF_Authorization` value must
    /// agree on before treating it as usable: it has to parse as a JWT *and*
    /// not be (about to be) expired. `AccessTokenStore.validToken(for:)` uses
    /// this to decide whether a stored token still needs a browser login, and
    /// `AccessLoginView`'s cookie capture uses the same rule to decide whether
    /// a captured cookie is worth committing — otherwise the two can disagree
    /// (capture accepts a token the store then immediately rejects) and the
    /// app blames the user for a token it captured itself.
    public static func usable(raw: String) -> AccessToken? {
        guard let token = AccessToken(raw: raw), !token.isExpired else { return nil }
        return token
    }

    private struct Payload: Decodable {
        let exp: Double
        let aud: Audience?
    }

    /// Access emits `aud` as an array; RFC 7519 also allows a bare string.
    private struct Audience: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let many = try? c.decode([String].self) {
                values = many
            } else {
                values = [try c.decode(String.self)]
            }
        }
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}
