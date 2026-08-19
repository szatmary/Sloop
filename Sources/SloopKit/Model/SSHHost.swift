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

/// How the byte stream to the host is established. `.direct` is a plain TCP
/// connection; the others ride a tunnel via a matching `Dialer`.
public enum ConnectionMethod: String, Codable, Hashable, CaseIterable {
    case direct
    case cloudflareAccess
    case tailscale

    /// How this reads in the host editor's picker. In the model, beside the
    /// cases, so a new method cannot be added without a name to show for it —
    /// the picker iterates `allCases` and would otherwise be one hand-written
    /// list that quietly stops covering the enum. (`SSHHost` already carries
    /// `connectionSummary` for the same kind of reason.) The raw values won't
    /// do: "CloudflareAccess" is a spelling no one would choose.
    public var displayName: String {
        switch self {
        case .direct: return "Direct"
        case .cloudflareAccess: return "Cloudflare Access"
        case .tailscale: return "Tailscale"
        }
    }
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
    /// How to reach the host. Tunneled methods are SSH-only (no Mosh — UDP
    /// can't traverse them).
    public var connectionMethod: ConnectionMethod
    /// A command typed into the shell each time this host connects, as if the
    /// user had entered it — `tmux attach || tmux new` being the case that
    /// motivates it. Optional so host files written before this existed still
    /// decode; empty and whitespace-only values run nothing.
    public var onConnectCommand: String?
    /// Whether this host is published to Files.app as a File Provider domain.
    ///
    /// On by default, including for hosts saved before this existed. Opt-in was
    /// the original design — a domain is a location the system may enumerate on
    /// its own schedule, so publishing everything has Files.app reaching servers
    /// nobody asked it to. In use that reasoning lost to a simpler fact: a host
    /// added in Sloop and then looked for in Files.app is not there, and nothing
    /// about the terminal suggests why. Someone who wants a host kept out still
    /// has the switch; someone who wants it in has to do nothing.
    public var showsInFiles: Bool
    /// The directory that domain is rooted at. Nil means the SFTP session's
    /// default directory, which on essentially every server is the login
    /// directory — the same place a fresh shell starts, and what someone
    /// tapping their host in Files.app expects to see.
    public var filesRootPath: String?

    public init(id: UUID = UUID(),
                alias: String,
                hostname: String,
                port: Int = 22,
                username: String,
                auth: AuthMethod = .password,
                useMosh: Bool = false,
                connectionMethod: ConnectionMethod = .direct,
                onConnectCommand: String? = nil,
                showsInFiles: Bool = true,
                filesRootPath: String? = nil) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.useMosh = useMosh
        self.connectionMethod = connectionMethod
        self.onConnectCommand = onConnectCommand
        self.showsInFiles = showsInFiles
        self.filesRootPath = filesRootPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, alias, hostname, port, username, auth, useMosh, connectionMethod
        case onConnectCommand, showsInFiles, filesRootPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        alias = try c.decode(String.self, forKey: .alias)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        auth = try c.decode(AuthMethod.self, forKey: .auth)
        useMosh = try c.decode(Bool.self, forKey: .useMosh)
        connectionMethod = try c.decodeIfPresent(ConnectionMethod.self,
                                                 forKey: .connectionMethod) ?? .direct
        onConnectCommand = try c.decodeIfPresent(String.self, forKey: .onConnectCommand)
        showsInFiles = try c.decodeIfPresent(Bool.self, forKey: .showsInFiles) ?? true
        filesRootPath = try c.decodeIfPresent(String.self, forKey: .filesRootPath)
    }

    /// The directory this host's Files.app domain is rooted at, or nil to use
    /// the server's default. Trimmed here so every caller agrees on what
    /// "blank" means — the same treatment `onConnectCommand` gets, for the same
    /// reason: a field the user cleared should mean "unset", not "the path
    /// named by the empty string".
    public var trimmedFilesRootPath: String? {
        guard let path = filesRootPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return RemotePath.normalize(path)
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
