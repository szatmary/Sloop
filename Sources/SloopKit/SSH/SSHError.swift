import Foundation

/// Errors surfaced by the SSH and Mosh transports.
public enum SSHError: Error, LocalizedError {
    case notImplemented(String)
    case connectionFailed(String)
    case authenticationFailed
    case channelFailure(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let what): return "not implemented: \(what)"
        case .connectionFailed(let why): return "connection failed: \(why)"
        case .authenticationFailed:      return "authentication failed"
        case .channelFailure(let why):   return "channel failure: \(why)"
        }
    }
}
