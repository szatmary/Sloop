import Foundation

/// Where per-host secrets live. The app ships a Keychain-backed implementation;
/// tests use `InMemoryCredentialStore`. Kept as a protocol in SloopKit so the
/// SSH plumbing can depend on it without pulling in the Security framework.
public protocol CredentialStore: AnyObject {
    func credential(for hostID: UUID) -> Credential?
    func setCredential(_ credential: Credential, for hostID: UUID) throws
    func removeCredential(for hostID: UUID) throws
}

/// A non-persistent credential store for tests and previews.
public final class InMemoryCredentialStore: CredentialStore {
    private var storage: [UUID: Credential] = [:]

    public init() {}

    public func credential(for hostID: UUID) -> Credential? { storage[hostID] }
    public func setCredential(_ credential: Credential, for hostID: UUID) throws {
        storage[hostID] = credential
    }
    public func removeCredential(for hostID: UUID) throws {
        storage[hostID] = nil
    }
}
