import Foundation

/// The lifecycle of a terminal's underlying transport, surfaced to the UI so it
/// can show a status indicator and offer reconnect.
///
/// A transport moves `connecting → connected` when its channel is ready (after
/// connect/auth for SSH; immediately for local transports), and
/// `→ disconnected` when it closes, carrying the failure reason if any.
public enum ConnectionState: Equatable {
    case connecting
    case connected
    case disconnected(reason: String?)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// True once the transport has finished — the point at which reconnect makes
    /// sense.
    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }

    /// A short human-readable label for the status indicator.
    public var label: String {
        switch self {
        case .connecting:
            return "Connecting…"
        case .connected:
            return "Connected"
        case .disconnected(let reason):
            return reason.map { "Disconnected — \($0)" } ?? "Disconnected"
        }
    }
}
