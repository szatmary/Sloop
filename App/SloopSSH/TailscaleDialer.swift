// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit
#if SLOOP_TAILSCALE
import CTailscale

/// Dials a host over Sloop's own tailnet node.
///
/// The whole integration fits behind `Dialer` because `tailscale_dial` hands
/// back an ordinary socket fd: libssh2 cannot tell a tailnet connection from a
/// direct one, and neither Mosh's bootstrap nor the known-hosts check needs to
/// know either.
public final class TailscaleDialer: Dialer {
    private let host: String
    private let port: Int
    private let role: SloopStorage.TailnetRole
    private let presenter: TailscaleAuthorizationPresenter

    public init(host: String, port: Int,
                role: SloopStorage.TailnetRole,
                presenter: TailscaleAuthorizationPresenter) {
        self.host = host
        self.port = port
        self.role = role
        self.presenter = presenter
    }

    public func dial() throws -> Int32 {
        // Bringing the node up is part of dialing, not of app launch: a user
        // with no tailnet hosts should never pay for a WireGuard node, and one
        // who has them expects the first connect to be where "authorize this
        // device" turns up.
        let node = TailscaleNode.node(for: role)
        do {
            try node.connect()
        } catch let error as TailscaleNode.NodeError {
            // An authorization URL is useless as terminal text — it can't be
            // tapped there. Raise the sheet, and still throw so the terminal
            // says why the connection stopped.
            if case .needsAuthorization(let url) = error {
                presenter.presentAuthorization(url)
            }
            throw error
        }
        return try node.dial(host: host, port: port)
    }
}
#endif
