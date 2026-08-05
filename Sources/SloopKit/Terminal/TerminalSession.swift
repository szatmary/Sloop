import Foundation

/// A live terminal session: a titled wrapper around a `Transport`.
///
/// It carries no UIKit/AppKit dependency so it can live in SloopKit and be
/// unit-tested. The app layer binds one of these to a SwiftTerm `TerminalView`.
public final class TerminalSession: Identifiable {
    public let id = UUID()
    public let title: String
    public let transport: Transport

    public init(title: String, transport: Transport) {
        self.title = title
        self.transport = transport
    }

    /// A throwaway local session for the "Local terminal" quick action.
    public static func localEcho() -> TerminalSession {
        TerminalSession(title: "local", transport: EchoTransport())
    }
}
