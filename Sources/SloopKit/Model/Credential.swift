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
    /// The matching public key (an OpenSSH `.pub` line). Passed to libssh2 when
    /// present; the OpenSSL 3 backend derives it otherwise. It exists because
    /// the mbedTLS backend this project used previously could not derive it, and
    /// every key authentication failed with "Username/PublicKey combination
    /// invalid" however valid the key was.
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
