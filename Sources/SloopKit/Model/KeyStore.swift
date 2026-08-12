import Foundation

/// A private key in the shared key library, referenced from hosts by
/// `AuthMethod.publicKey(name:)`. The library is the "import once, use from
/// any host" tier; per-host `Credential`s remain the legacy/fallback tier.
public struct NamedKey: Codable, Equatable, Identifiable {
    /// Unique within the library, e.g. "id_ed25519".
    public var name: String
    public var privateKeyPEM: String
    public var passphrase: String?

    public var id: String { name }

    public init(name: String, privateKeyPEM: String, passphrase: String? = nil) {
        self.name = name
        self.privateKeyPEM = privateKeyPEM
        self.passphrase = passphrase
    }
}

/// Where library keys live. The app ships a keychain-backed implementation
/// (synchronizable via iCloud Keychain); tests use `InMemoryKeyStore`. A
/// protocol in SloopKit so resolution/migration logic stays Foundation-only.
public protocol KeyStore: AnyObject {
    /// All keys, sorted by name.
    func keys() -> [NamedKey]
    func key(named name: String) -> NamedKey?
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
