// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// An `ssh://user@host:port` link, parsed.
///
/// This is how people share a host — in a runbook, a ticket, a chat message —
/// so tapping one should land in Sloop rather than doing nothing. Pure and
/// Foundation-only: deciding what to *do* with the link (connect to a host you
/// already trust, or open the editor prefilled) is the app's business, not this
/// type's.
public struct SSHURL: Equatable, Sendable {
    public let hostname: String
    public let username: String?
    public let port: Int?

    /// SSH's own default, so a link without a port behaves like `ssh host`.
    public static let defaultPort = 22

    public init?(string: String) {
        guard let components = URLComponents(string: string),
              components.scheme?.lowercased() == "ssh"
        else { return nil }

        // URLComponents strips the brackets RFC 3986 puts around an IPv6
        // literal to keep its colons from reading as a port — but not on every
        // platform, so strip them here too. libssh2 wants the bare address.
        guard let rawHost = components.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast())
            : rawHost
        guard !host.isEmpty else { return nil }
        self.hostname = host

        // `components.user` is already percent-decoded.
        if let user = components.user, !user.isEmpty {
            self.username = user
        } else {
            self.username = nil
        }

        if let port = components.port {
            // Out of range is not a port. Rejecting here fails clearly, rather
            // than handing libssh2 a value it cannot use and failing later.
            guard (1...65535).contains(port) else { return nil }
            self.port = port
        } else {
            self.port = nil
        }
    }

    /// A host to save or edit, for a link that matches nothing already saved.
    ///
    /// The alias is the hostname because the link carries no better name; the
    /// user renames it in the editor if they want one.
    public func makeHost() -> SSHHost {
        SSHHost(alias: hostname,
                hostname: hostname,
                port: port ?? Self.defaultPort,
                username: username ?? "")
    }

    /// Whether a saved host is the one this link points at.
    ///
    /// A link naming no user is a link about a machine rather than an account,
    /// so it matches whatever account you already saved for that machine.
    /// Hostnames are compared case-insensitively because DNS is.
    public func matches(_ host: SSHHost) -> Bool {
        guard host.hostname.lowercased() == hostname.lowercased() else { return false }
        guard (port ?? Self.defaultPort) == host.port else { return false }
        guard let username else { return true }
        return username == host.username
    }
}
