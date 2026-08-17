// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Errors surfaced by the SSH and Mosh transports.
public enum SSHError: Error, LocalizedError {
    case notImplemented(String)
    case connectionFailed(String)
    /// Carries why: a wrong password, a key the server rejected, and a host
    /// with no credential configured at all are three different problems and
    /// must not present as the same message.
    case authenticationFailed(String)
    case channelFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let what): return "not implemented: \(what)"
        case .connectionFailed(let why): return "connection failed: \(why)"
        case .authenticationFailed(let why): return "authentication failed: \(why)"
        case .channelFailure(let why):   return "channel failure: \(why)"
        }
    }
}
