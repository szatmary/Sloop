// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A secret used to authenticate to a host.
///
/// Kept separate from `Host` so hosts can be persisted as plain JSON while
/// secrets live in the keychain. At connect time the app looks up the
/// credential for a host and hands it to the SSH transport.
public struct Credential: Codable, Equatable {
    public var password: String?
    public var privateKeyPEM: String?
    /// The matching public key (an OpenSSH `.pub` line). Required for key auth:
    /// libssh2's mbedTLS backend cannot derive a public key from a private one
    /// in memory, so without this every key authentication fails with
    /// "Username/PublicKey combination invalid" no matter how valid the key is.
    public var publicKey: String?
    public var passphrase: String?

    public init(password: String? = nil,
                privateKeyPEM: String? = nil,
                publicKey: String? = nil,
                passphrase: String? = nil) {
        self.password = password
        self.privateKeyPEM = privateKeyPEM
        self.publicKey = publicKey
        self.passphrase = passphrase
    }
}
