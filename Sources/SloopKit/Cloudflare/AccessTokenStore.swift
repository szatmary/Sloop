import Foundation

/// Where Cloudflare Access tokens live, one per Access-protected hostname.
/// The app ships a Keychain-backed implementation; tests use
/// `InMemoryAccessTokenStore`. Kept as a protocol in SloopKit so the dial
/// plumbing can depend on it without pulling in the Security framework.
public protocol AccessTokenStore: AnyObject {
    func rawToken(for hostname: String) -> String?
    func setRawToken(_ raw: String, for hostname: String) throws
    func removeToken(for hostname: String) throws
}

public extension AccessTokenStore {
    /// The stored token, parsed, iff it exists and isn't (about to be)
    /// expired. `nil` always means "a browser login is needed".
    func validToken(for hostname: String) -> AccessToken? {
        guard let raw = rawToken(for: hostname),
              let token = AccessToken(raw: raw),
              !token.isExpired else { return nil }
        return token
    }
}

/// A non-persistent token store for tests and previews.
public final class InMemoryAccessTokenStore: AccessTokenStore {
    private var storage: [String: String] = [:]

    public init() {}

    public func rawToken(for hostname: String) -> String? { storage[hostname] }
    public func setRawToken(_ raw: String, for hostname: String) throws {
        storage[hostname] = raw
    }
    public func removeToken(for hostname: String) throws {
        storage[hostname] = nil
    }
}
