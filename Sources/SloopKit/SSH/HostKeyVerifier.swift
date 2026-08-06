import Foundation

/// Decides whether to trust a host key.
///
/// The SSH connection loop consults a verifier in two situations reported by
/// `KnownHostsStore`:
///
/// - **Unknown endpoint** (trust-on-first-use) → `shouldTrust(...)`.
/// - **Changed key** — the endpoint is known but its key no longer matches what
///   we recorded, a possible MITM → `shouldTrustChangedKey(...)`.
///
/// Implementations are called off the main thread from the SSH connection loop
/// and must be thread-safe; an interactive one typically blocks the SSH thread
/// while it presents UI and waits for the user's choice.
public protocol HostKeyVerifier: AnyObject {
    /// A never-before-seen endpoint. Return `true` to trust (and remember) the
    /// key, `false` to refuse the connection.
    func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool

    /// A known endpoint whose key changed. `previousFingerprint` is the key we
    /// had on record. Return `true` to accept and replace the stored key,
    /// `false` to refuse. The default refuses — accepting a changed key should
    /// be a deliberate, user-confirmed action.
    func shouldTrustChangedKey(endpoint: String,
                               keyType: String,
                               fingerprint: String,
                               previousFingerprint: String) -> Bool
}

public extension HostKeyVerifier {
    /// Safe default: refuse a changed key unless an implementation opts in.
    func shouldTrustChangedKey(endpoint: String,
                               keyType: String,
                               fingerprint: String,
                               previousFingerprint: String) -> Bool {
        false
    }
}

/// Trusts every new host on first sight — the previous built-in behavior. Fine
/// for development; production should prompt the user instead. Changed keys are
/// still refused (via the protocol default), since a changed key is a different,
/// more dangerous situation than a first connection.
public final class AutoAcceptHostKeyVerifier: HostKeyVerifier {
    public init() {}
    public func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool {
        true
    }
}

/// A verifier backed by closures — used for tests and to bridge the SSH loop to
/// an interactive UI prompt. The changed-key closure defaults to refusing.
public final class ClosureHostKeyVerifier: HostKeyVerifier {
    private let decide: (_ endpoint: String, _ keyType: String, _ fingerprint: String) -> Bool
    private let decideChanged: (_ endpoint: String, _ keyType: String, _ fingerprint: String, _ previous: String) -> Bool

    public init(onUnknown decide: @escaping (String, String, String) -> Bool,
                onChanged: @escaping (String, String, String, String) -> Bool) {
        self.decide = decide
        self.decideChanged = onChanged
    }

    /// Convenience for the common case of deciding only about unknown keys
    /// (changed keys are refused). Keeping this the only single-closure
    /// initializer avoids a trailing-closure ambiguity with `init(onUnknown:onChanged:)`.
    public convenience init(_ decide: @escaping (String, String, String) -> Bool) {
        self.init(onUnknown: decide, onChanged: { _, _, _, _ in false })
    }

    public func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool {
        decide(endpoint, keyType, fingerprint)
    }

    public func shouldTrustChangedKey(endpoint: String,
                                      keyType: String,
                                      fingerprint: String,
                                      previousFingerprint: String) -> Bool {
        decideChanged(endpoint, keyType, fingerprint, previousFingerprint)
    }
}
