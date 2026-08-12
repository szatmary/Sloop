import Foundation

/// Connect-time key resolution and one-time migration for the shared key
/// library. Pure functions over the store protocols so both are unit-testable
/// without the keychain.
public enum KeyLibrary {
    /// The credential to hand the SSH transport for `host`.
    ///
    /// `.publicKey(name:)` prefers the library key of that name; if the
    /// library has none (pre-migration data, or a removed key) it falls back
    /// to the legacy per-host credential. Password hosts always use the
    /// per-host credential.
    public static func credential(for host: SSHHost,
                                  keys: KeyStore,
                                  credentials: CredentialStore) -> Credential? {
        if case .publicKey(let name) = host.auth, let key = keys.key(named: name) {
            return Credential(privateKeyPEM: key.privateKeyPEM, passphrase: key.passphrase)
        }
        return credentials.credential(for: host.id)
    }

    /// Lift legacy per-host PEMs into the library, named by each host's
    /// existing `.publicKey(name:)`. Idempotent: existing library entries are
    /// never overwritten (they may be newer, or synced from another device).
    /// The per-host copy is left in place as the fallback tier.
    public static func migrate(hosts: [SSHHost],
                               credentials: CredentialStore,
                               keys: KeyStore) {
        for host in hosts {
            guard case .publicKey(let name) = host.auth,
                  keys.key(named: name) == nil,
                  let credential = credentials.credential(for: host.id),
                  let pem = credential.privateKeyPEM else { continue }
            try? keys.setKey(NamedKey(name: name,
                                      privateKeyPEM: pem,
                                      passphrase: credential.passphrase))
        }
    }
}
