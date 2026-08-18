// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// How Sloop authenticates to a host. Secrets never live here — see `Credential`.
public enum AuthMethod: Codable, Hashable {
    case password
    /// References a private key stored in the keychain by name.
    case publicKey(name: String)
    case agent
}

/// A saved connection. Persisted as plain JSON via `HostStore`; the matching
/// secret is looked up separately at connect time so this stays keychain-free.
public struct SSHHost: Identifiable, Codable, Hashable {
    public var id: UUID
    public var alias: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var auth: AuthMethod
    /// Prefer Mosh when `mosh-server` is available on the host.
    public var useMosh: Bool
    /// A command typed into the shell each time this host connects, as if the
    /// user had entered it — `tmux attach || tmux new` being the case that
    /// motivates it. Optional so host files written before this existed still
    /// decode; empty and whitespace-only values run nothing.
    public var onConnectCommand: String?

    public init(id: UUID = UUID(),
                alias: String,
                hostname: String,
                port: Int = 22,
                username: String,
                auth: AuthMethod = .password,
                useMosh: Bool = false,
                onConnectCommand: String? = nil) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.useMosh = useMosh
        self.onConnectCommand = onConnectCommand
    }

    /// The command to send on connect, or nil when there's nothing to run.
    /// Trimmed here so every caller agrees on what "blank" means.
    public var trimmedOnConnectCommand: String? {
        guard let command = onConnectCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return nil }
        return command
    }

    /// A display string like `matt@example.com:22`.
    public var connectionSummary: String {
        "\(username)@\(hostname)" + (port == 22 ? "" : ":\(port)")
    }
}
