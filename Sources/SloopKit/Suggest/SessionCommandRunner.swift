// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A transport that can answer a question about the host using a connection the
/// session already has.
///
/// A protocol rather than a cast to a concrete type. The first version of the
/// history import asked `transport as? LibSSH2Transport`, which is true for a
/// plain SSH host and false for every host with Mosh enabled — those get a
/// `MoshOrSSHTransport` wrapping the real one — so the import silently did
/// nothing on exactly the hosts most likely to be used. A composing transport
/// can forward this; a cast has no way to.
public protocol SessionCommandRunner {
    /// Ask for `command`'s output, and register the request **before
    /// `start()`**.
    ///
    /// Registering, not invoking: the transport decides *when* it can afford to
    /// ask, and the honest answer differs by transport. An SSH session waits
    /// until the shell is up and then opens a second channel, because the
    /// connection the user asked for does not get to queue behind a
    /// convenience. A Mosh session has to ask during its bootstrap exec — that
    /// is the only SSH connection it will ever have, and it is gone before the
    /// terminal opens.
    ///
    /// Leaving that timing to the caller is what forked the shell-history
    /// import in two: one path for SSH, and a second, history-shaped callback
    /// on the composite transport for Mosh, reachable only by casting to it.
    ///
    /// The completion fires exactly once — with `nil` when there was no
    /// connection to ask on, including when the request arrived too late for a
    /// Mosh session or the session closed first. Never a completion that never
    /// fires: a caller waiting on one waits forever.
    func requestOnSession(_ command: String, completion: @escaping (String?) -> Void)
}
