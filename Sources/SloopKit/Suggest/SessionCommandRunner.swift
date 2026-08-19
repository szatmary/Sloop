// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A transport that can run a command on the connection it already holds.
///
/// A protocol rather than a cast to a concrete type. The first version of the
/// history import asked `transport as? LibSSH2Transport`, which is true for a
/// plain SSH host and false for every host with Mosh enabled — those get a
/// `MoshOrSSHTransport` wrapping the real one — so the import silently did
/// nothing on exactly the hosts most likely to be used. A composing transport
/// can forward this; a cast has no way to.
public protocol SessionCommandRunner {
    /// Run `command` on the existing connection and return what it printed, or
    /// nil if it couldn't run — no connection of that kind, or the channel
    /// failed. Never opens a connection of its own: the point is to cost
    /// nothing beyond what the session already has.
    func runOnSession(_ command: String, completion: @escaping (String?) -> Void)
}
