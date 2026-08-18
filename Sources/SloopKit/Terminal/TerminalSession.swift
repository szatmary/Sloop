// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

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
    /// Typed into the shell every time this session's transport opens — on
    /// first connect and on every reconnect, which is the point: a dropped
    /// link should land back in `tmux attach`, not at a bare prompt.
    public let onConnectCommand: String?

    /// The saved host this session connects to, when it came from one.
    ///
    /// Identity, not configuration: it is what lets a session find the command
    /// history belonging to *that machine*, rather than one shared across every
    /// host — which would offer each the other's commands, and each of those is
    /// a record of what someone did on a particular machine.
    public let hostID: UUID?
    private let makeTransport: () -> Transport

    public init(title: String,
                onConnectCommand: String? = nil,
                hostID: UUID? = nil,
                makeTransport: @escaping () -> Transport) {
        self.title = title
        self.onConnectCommand = onConnectCommand
        self.hostID = hostID
        self.makeTransport = makeTransport
    }

    /// Convenience for a single, pre-built transport. Reconnecting reuses the
    /// same instance, so this suits tests rather than SSH (which should pass a
    /// factory that builds a fresh connection).
    public convenience init(title: String,
                            onConnectCommand: String? = nil,
                            hostID: UUID? = nil,
                            transport: Transport) {
        self.init(title: title, onConnectCommand: onConnectCommand, hostID: hostID,
                  makeTransport: { transport })
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

}
