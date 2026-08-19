// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Marks a failure that only a person, in the app, can clear.
///
/// The File Provider extension has no UI and cannot ask for anything, so it has
/// to tell the system which failures are worth retrying and which are not. An
/// error it does not recognize is treated as transient and retried forever —
/// which for "authorize this device on your tailnet" means a silent loop
/// instead of a sign-in affordance. Conforming is how a new error opts out of
/// that, rather than by being listed in a `switch` somewhere else that nobody
/// updates.
public protocol UserActionRequiredError: Error {}

extension SSHError: UserActionRequiredError {}

/// Errors surfaced by the SSH and Mosh transports.
public enum SSHError: Error, LocalizedError {
    case notImplemented(String)
    case connectionFailed(String)
    /// Carries why: a wrong password, a key the server rejected, and a host
    /// with no credential configured at all are three different problems and
    /// must not present as the same message.
    case authenticationFailed(String)
    case channelFailure(String)
    /// The Cloudflare Access token for this host is missing, expired, or was
    /// rejected — a fresh browser login will fix it.
    case accessLoginRequired(host: String)
    /// Cloudflare Access authenticated the identity but the policy denied it.
    case accessDenied(host: String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let what): return "not implemented: \(what)"
        case .connectionFailed(let why): return "connection failed: \(why)"
        case .authenticationFailed(let why): return "authentication failed: \(why)"
        case .channelFailure(let why):   return "channel failure: \(why)"
        case .accessLoginRequired(let host):
            return "Cloudflare Access needs a browser login for \(host)"
        case .accessDenied(let host):
            return "Cloudflare Access denied this identity for \(host)"
        }
    }
}
