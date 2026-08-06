import Foundation

/// A live terminal session: a titled factory for a `Transport`.
///
/// It holds a *factory* rather than a single transport because transports are
/// one-shot (an SSH connection runs on a thread that finishes when the link
/// drops), so reconnecting means building a fresh transport. It carries no
/// UIKit/AppKit dependency so it can live in SloopKit and be unit-tested; the
/// app layer binds one of these to a SwiftTerm `TerminalView`.
public final class TerminalSession: Identifiable, Hashable {
    public let id = UUID()
    public let title: String
    private let makeTransport: () -> Transport

    public init(title: String, makeTransport: @escaping () -> Transport) {
        self.title = title
        self.makeTransport = makeTransport
    }

    /// Convenience for a single, pre-built transport. Reconnecting reuses the
    /// same instance, so this suits local/echo transports and tests rather than
    /// SSH (which should pass a factory that builds a fresh connection).
    public convenience init(title: String, transport: Transport) {
        self.init(title: title, makeTransport: { transport })
    }

    /// Build a fresh transport for this session — used on first connect and on
    /// each reconnect.
    public func newTransport() -> Transport { makeTransport() }

    // Identity-based conformance — each session is a distinct object.
    // (Required by SwiftUI's navigationDestination(item:), which wants Hashable.)
    public static func == (lhs: TerminalSession, rhs: TerminalSession) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// A throwaway local session for the "Local terminal" quick action.
    public static func localEcho() -> TerminalSession {
        TerminalSession(title: "local") { EchoTransport() }
    }
}
