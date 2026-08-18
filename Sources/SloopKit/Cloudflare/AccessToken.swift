// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A Cloudflare Access application token (`CF_Authorization` JWT). The app is
/// the bearer, not the verifier, so only the payload's `exp` claim is parsed
/// (no signature check) — enough to know when a fresh browser login is needed
/// before we bother dialing.
///
/// Nothing else in the payload is read, `aud` included. Checking the audience
/// here would only duplicate, badly, what Cloudflare's edge does properly on
/// every dial: it rejects a token whose `aud` doesn't match the application
/// being reached, and that rejection is already handled
/// (`SSHError.accessDenied`, and `TokenClearingDialer` clearing the token).
/// Parsing it cost an availability regression instead — a payload whose `aud`
/// was shaped unexpectedly failed the whole decode, throwing away a token
/// whose expiry was perfectly readable and which the edge might well have
/// accepted.
public struct AccessToken: Equatable {
    public let raw: String
    public let expiresAt: Date

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

    /// Only what is actually used. Unknown keys are ignored by `Decodable`,
    /// so a claim this app has no opinion about can never cost the user a
    /// usable token.
    private struct Payload: Decodable {
        let exp: Double
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}
