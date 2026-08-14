import Foundation

/// Errors surfaced by the SSH and Mosh transports.
public enum SSHError: Error, LocalizedError {
    case notImplemented(String)
    case connectionFailed(String)
    case authenticationFailed
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
        case .authenticationFailed:      return "authentication failed"
        case .channelFailure(let why):   return "channel failure: \(why)"
        case .accessLoginRequired(let host):
            return "Cloudflare Access needs a browser login for \(host)"
        case .accessDenied(let host):
            return "Cloudflare Access denied this identity for \(host)"
        }
    }
}
