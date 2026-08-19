// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// One key exposed to a forwarded agent.
///
/// `blob` is the wire-format public key — the same bytes as the base64 middle
/// field of an OpenSSH `.pub` line — and is what a `SIGN_REQUEST` names when
/// it asks for a signature. `keyName` is the library name it was derived from,
/// which is how a signature request gets back to a private key.
public struct AgentIdentity: Equatable {
    public let keyName: String
    public let algorithm: String
    public let blob: [UInt8]
    public var comment: String

    public init(keyName: String, algorithm: String, blob: [UInt8], comment: String) {
        self.keyName = keyName
        self.algorithm = algorithm
        self.blob = blob
        self.comment = comment
    }
}
