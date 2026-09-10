// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A private key in the shared key library, referenced from hosts by
/// `AuthMethod.publicKey(name:)`. The library is the "import once, use from
/// any host" tier; per-host `Credential`s remain the legacy/fallback tier.
public struct NamedKey: Codable, Equatable, Identifiable {
    /// Unique within the library, e.g. "id_ed25519".
    public var name: String
    public var privateKeyPEM: String
    /// The matching public key (an OpenSSH `.pub` line). Optional: the OpenSSL 3
    /// backend derives it from the private key, so a key without one still
    /// authenticates. Stored when available because backends differ — libssh2's
    /// mbedTLS backend could not derive it, which is why this field exists at
    /// all (see `Docs/SSH.md`) — and because it costs a few hundred bytes.
    public var publicKey: String?
    public var passphrase: String?

    public var id: String { name }

    public init(name: String,
                privateKeyPEM: String,
                publicKey: String? = nil,
                passphrase: String? = nil) {
        self.name = name
        self.privateKeyPEM = privateKeyPEM
        self.publicKey = publicKey
        self.passphrase = passphrase
    }
}

/// Where library keys live. The app ships a keychain-backed implementation
/// (synchronizable via iCloud Keychain); tests use `InMemoryKeyStore`. A
/// protocol in SloopKit so resolution/migration logic stays Foundation-only.
/// Reads throw rather than reporting failure as absence. An empty library and
/// an unreadable one look identical to a caller that gets `[]` for both, and
/// they are not the same answer: the keychain refuses reads outright when a
/// build lacks the access-group entitlement, which then presents as "you have
/// no keys" — sending the user to re-import keys that were there all along,
/// and turning a signing problem into an auth failure at connect time.
public protocol KeyStore: AnyObject {
    /// All keys, sorted by name. Empty means the library is empty.
    func keys() throws -> [NamedKey]
    /// The named key, or nil if the library genuinely has no such key.
    func key(named name: String) throws -> NamedKey?
    /// Insert or replace the key with the same name.
    func setKey(_ key: NamedKey) throws
    /// Removing an absent name is not an error.
    func removeKey(named name: String) throws
}

/// A non-persistent key store for tests and previews.
public final class InMemoryKeyStore: KeyStore {
    private var storage: [String: NamedKey] = [:]

    public init() {}

    public func keys() -> [NamedKey] {
        storage.values.sorted { $0.name < $1.name }
    }
    public func key(named name: String) -> NamedKey? { storage[name] }
    public func setKey(_ key: NamedKey) throws { storage[key.name] = key }
    public func removeKey(named name: String) throws { storage[name] = nil }
}
