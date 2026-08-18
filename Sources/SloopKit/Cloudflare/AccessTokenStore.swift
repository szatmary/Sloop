// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Where Cloudflare Access tokens live, one per Access-protected hostname.
/// The app ships a Keychain-backed implementation; tests use
/// `InMemoryAccessTokenStore`. Kept as a protocol in SloopKit so the dial
/// plumbing can depend on it without pulling in the Security framework.
///
/// **Conformances must be safe to use from several threads at once**, which
/// is why this protocol is `Sendable`. One store is shared by the whole app
/// and it is genuinely used concurrently: `HostListModel` reads and writes it
/// on the main actor (the pre-connect check, storing a freshly captured
/// token, signing out, deleting a host) while `TokenClearingDialer` removes a
/// rejected token from whichever SSH worker thread was dialing at the time.
/// An unsynchronized dictionary or a check-then-act keychain update under
/// that is undefined behaviour, not a lost update.
public protocol AccessTokenStore: AnyObject, Sendable {
    func rawToken(for hostname: String) -> String?
    func setRawToken(_ raw: String, for hostname: String) throws
    func removeToken(for hostname: String) throws
}

public extension AccessTokenStore {
    /// The stored token, parsed, iff it exists and isn't (about to be)
    /// expired. `nil` always means "a browser login is needed". Delegates the
    /// parse-and-expiry check to `AccessToken.usable(raw:)` so this and the
    /// cookie-capture path in `AccessLoginView` can never disagree about what
    /// counts as a usable token.
    func validToken(for hostname: String) -> AccessToken? {
        guard let raw = rawToken(for: hostname) else { return nil }
        return AccessToken.usable(raw: raw)
    }
}

/// Hostnames are case-insensitive, but reach a store in whatever case the
/// user typed or an imported SSH config used (`SSHConfigParser` copies
/// `HostName` verbatim). Every `AccessTokenStore` conformance normalizes a
/// hostname through this before using it as a storage key, so the same host
/// — however it was typed — always resolves to the same token. This never
/// changes what's displayed to the user; only the storage key is affected.
public func normalizedAccessHostname(_ hostname: String) -> String {
    hostname.lowercased()
}

/// A non-persistent token store for tests and previews.
///
/// `@unchecked Sendable` is earned by the lock, not assumed: every access to
/// `storage` goes through it, so the concurrent use the protocol allows is
/// serialized here rather than corrupting a Dictionary mid-resize.
public final class InMemoryAccessTokenStore: AccessTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func rawToken(for hostname: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[normalizedAccessHostname(hostname)]
    }
    public func setRawToken(_ raw: String, for hostname: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[normalizedAccessHostname(hostname)] = raw
    }
    public func removeToken(for hostname: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[normalizedAccessHostname(hostname)] = nil
    }
}
