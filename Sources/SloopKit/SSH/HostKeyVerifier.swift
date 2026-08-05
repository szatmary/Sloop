import Foundation

/// Decides whether to trust a host key the client hasn't seen before.
///
/// `LibSSH2Transport` consults a verifier when `KnownHostsStore` reports an
/// unknown endpoint (trust-on-first-use). Implementations are called off the
/// main thread from the SSH connection loop and must be thread-safe; an
/// interactive one typically blocks the SSH thread while it presents UI and
/// waits for the user's choice.
public protocol HostKeyVerifier: AnyObject {
    /// Return `true` to trust (and remember) the key, `false` to refuse the
    /// connection.
    func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool
}

/// Trusts every new host on first sight — the previous built-in behavior. Fine
/// for development; production should prompt the user instead.
public final class AutoAcceptHostKeyVerifier: HostKeyVerifier {
    public init() {}
    public func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool {
        true
    }
}

/// A verifier backed by a closure — used for tests and to bridge the SSH loop to
/// an interactive UI prompt.
public final class ClosureHostKeyVerifier: HostKeyVerifier {
    private let decide: (_ endpoint: String, _ keyType: String, _ fingerprint: String) -> Bool

    public init(_ decide: @escaping (String, String, String) -> Bool) {
        self.decide = decide
    }

    public func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool {
        decide(endpoint, keyType, fingerprint)
    }
}
