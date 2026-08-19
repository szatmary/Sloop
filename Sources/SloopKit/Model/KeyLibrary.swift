// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Connect-time key resolution and one-time migration for the shared key
/// library. Pure functions over the store protocols so both are unit-testable
/// without the keychain.
public enum KeyLibrary {
    /// The credential to hand the SSH transport for `host`.
    ///
    /// `.publicKey(name:)` prefers the library key of that name; if the
    /// library has none (pre-migration data, or a removed key) it falls back
    /// to the legacy per-host credential — but only if that credential
    /// actually carries a private key. A `.publicKey` host must never resolve
    /// to a password-only legacy credential: `LibSSH2Transport` picks key vs.
    /// password auth from the credential's contents, so returning a stale
    /// password would silently re-send it to a host the user migrated to key
    /// auth. Password hosts always use the per-host credential.
    /// Throws if either store can't be read. The fallback below is for a key
    /// the library doesn't *have*; applying it to a library we merely failed to
    /// read would send a stale legacy credential to the host — and, when the
    /// read failed for want of an entitlement, would report a signing problem
    /// as an authentication failure.
    public static func credential(for host: SSHHost,
                                  keys: KeyStore,
                                  credentials: CredentialStore) throws -> Credential? {
        if case .publicKey(let name) = host.auth {
            if let key = try keys.key(named: name) {
                return Credential(privateKeyPEM: key.privateKeyPEM,
                                  publicKey: key.publicKey,
                                  passphrase: key.passphrase)
            }
            guard let legacy = try credentials.credential(for: host.id),
                  legacy.privateKeyPEM != nil else { return nil }
            return legacy
        }
        return try credentials.credential(for: host.id)
    }

    /// Lift legacy per-host PEMs into the library, named by each host's
    /// existing `.publicKey(name:)`. Idempotent: existing library entries are
    /// never overwritten (they may be newer, or synced from another device).
    /// The per-host copy is left in place as the fallback tier.
    ///
    /// This function is pure and safe to call repeatedly, but it is intended
    /// to run **once per device**: because it never overwrites an existing
    /// library entry, it also can't tell a key the user deliberately removed
    /// from the library (via `sloop remove-key`) apart from one that was
    /// simply never migrated. Calling it again after a removal re-lifts the
    /// legacy per-host PEM and effectively undoes the removal. Callers that
    /// run this at every launch (as the app does) must gate it behind a
    /// persisted "already migrated" marker of their own — see
    /// `HostListModel` for the app-layer marker. SloopKit itself stays
    /// Foundation-only and has no place to durably store that marker, so it
    /// isn't kept here.
    ///
    /// Throws on the first store failure rather than skipping that host: a
    /// migration that silently lifted some keys and not others leaves the user
    /// with a library that looks complete and hosts that can't authenticate.
    /// Callers set their "already migrated" marker only if this returns.
    public static func migrate(hosts: [SSHHost],
                               credentials: CredentialStore,
                               keys: KeyStore) throws {
        for host in hosts {
            guard case .publicKey(let name) = host.auth,
                  try keys.key(named: name) == nil,
                  let credential = try credentials.credential(for: host.id),
                  let pem = credential.privateKeyPEM else { continue }
            try keys.setKey(NamedKey(name: name,
                                     privateKeyPEM: pem,
                                     passphrase: credential.passphrase))
        }
    }

    /// The library keys this host exposes to a forwarded agent, in the order
    /// they were selected. Names with no key behind them are dropped: a key
    /// deleted from the library after the host was configured should cost that
    /// one identity, not the whole connection.
    ///
    /// Throws if the store can't be read, like `credential(for:keys:credentials:)`
    /// above and for the same reason: an unreadable library and an empty one are
    /// not the same answer, and reporting the first as the second would silently
    /// forward nothing.
    public static func forwardedKeys(for host: SSHHost, keys: KeyStore) throws -> [NamedKey] {
        try host.forwardedKeys.compactMap { try keys.key(named: $0) }
    }
}
