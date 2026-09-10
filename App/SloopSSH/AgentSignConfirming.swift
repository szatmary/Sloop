// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Asks the user whether a forwarded agent may sign with a given key.
///
/// Declared here rather than beside its implementation because it crosses the
/// boundary: the forwarded agent lives in this framework and does the asking,
/// while the only thing that can answer — a sheet — lives in the app.
public protocol AgentSignConfirming {
    /// Called on the SSH thread. Blocks until the user answers.
    func shouldSign(keyName: String, endpoint: String) -> Bool
}

/// Refuses every request. The default for contexts with no user to ask — the
/// File Provider extension, and anything running without UI. Refusing is the
/// only safe answer there: a signature the user never saw is exactly what
/// confirmation exists to prevent.
public struct DenyingSignConfirmer: AgentSignConfirming {
    public init() {}
    public func shouldSign(keyName: String, endpoint: String) -> Bool { false }
}
