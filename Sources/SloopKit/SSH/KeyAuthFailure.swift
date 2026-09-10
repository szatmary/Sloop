// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Turns libssh2's account of a failed key authentication into one a person can
/// act on.
///
/// libssh2 reports a private key it could not decrypt as `-19 Callback returned
/// error`, which is what a wrong passphrase looks like — the likeliest failure
/// there is, and the one its message helps with least. Measured against a real
/// server: every supported key type authenticates, and the wrong passphrase is
/// the only failure that arises from the client side.
public enum KeyAuthFailure {
    /// libssh2's `LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED`.
    public static let publicKeyUnverified: Int32 = -19

    public static func message(code: Int32,
                               libssh2Message: String,
                               hasPassphrase: Bool,
                               username: String) -> String {
        if hasPassphrase, code == publicKeyUnverified {
            return "The passphrase for this key looks wrong — the key couldn't be "
                 + "unlocked, so it was never offered to the server. Edit the host "
                 + "and enter it again."
        }
        if !hasPassphrase, code == publicKeyUnverified {
            return "This key couldn't be read. If it has a passphrase, edit the host "
                 + "and enter it: a key that can't be unlocked is never offered to "
                 + "the server."
        }
        return "The server rejected the key for '\(username)' — \(libssh2Message)"
    }
}
