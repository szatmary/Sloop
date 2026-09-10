// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit
import SloopSSH

/// Builds the Mosh half of a session, or says there isn't one.
///
/// The sibling of `TransportFactory`, and here for the same reason it is: a
/// connection has two legs, and deciding them in two different places is how
/// they stop agreeing. `TransportFactory` answers "how does the SSH leg get its
/// bytes" — `HostDialer`, one switch over `ConnectionMethod`. This answers the
/// same question for Mosh's SSP leg, which does *not* pass through `Dialer`:
/// `MoshTransport` gets a socket of its own, so a tunnel that carries SSH has
/// to be asked separately whether it can carry datagrams.
///
/// It also owns the build-variant conditionals. They were two nested `#if`
/// blocks assembling a `var` inside a closure inside `HostListModel.connect`,
/// which made a view model the place that knows which xcframeworks this build
/// links.
///
/// In the app rather than the `SloopSSH` framework because `MoshTransport` is:
/// the mosh C API arrives through the app's bridging header.
enum MoshTransportFactory {
    /// A factory for the Mosh transport this host would use, or `nil` when
    /// there is none — this build has no Mosh, or the host's connection method
    /// can't carry UDP. `MoshOrSSHTransport` reads `nil` as "probe, then use
    /// SSH whatever the answer", which is exactly right.
    static func make(for host: SSHHost) -> ((MoshBootstrap) -> Transport)? {
        #if SLOOP_MOSH
        // A method that can't carry a datagram gets no Mosh transport, whatever
        // the host file says: the editor won't let the toggle be on for one, but
        // a host saved before that was true still can.
        guard host.connectionMethod.carriesMosh else { return nil }

        #if SLOOP_TAILSCALE
        // A tailnet host has no address this process can route to — the SSH leg
        // goes through tsnet, and so must the SSP leg, or mosh would send its
        // packets into a network that has never heard of 100.64.0.0/10.
        if host.connectionMethod == .tailscale {
            return { bootstrap in
                MoshTransport(host: host.hostname, bootstrap: bootstrap) {
                    // The app's own node, not the File Provider's: they are
                    // separate processes with separate tailnet state, and this
                    // session belongs to the app.
                    try TailscaleNode.node(for: .app).dialUDP(host: host.hostname,
                                                              port: bootstrap.udpPort)
                }
            }
        }
        #endif

        // The address the SSH leg reached, not the name the user typed: mosh
        // resolves with `AI_NUMERICHOST | AI_NUMERICSERV` and throws
        // `NetworkException("Bad IP address")` for anything else, so a host
        // saved by DNS name failed the instant it said "connected". Upstream's
        // `mosh` wrapper resolves before exec; nothing here did.
        //
        // Falls back to the hostname, which is right when it *is* an address
        // and is the previous behaviour otherwise.
        return { bootstrap in
            MoshTransport(host: bootstrap.serverAddress ?? host.hostname, bootstrap: bootstrap)
        }
        #else
        // No mosh.xcframework in this build. The composite still probes and
        // still reports which mode the session got; it just never gets Mosh.
        return nil
        #endif
    }
}
