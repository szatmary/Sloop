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
public struct Host: Identifiable, Codable, Hashable {
    public var id: UUID
    public var alias: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var auth: AuthMethod
    /// Prefer Mosh when `mosh-server` is available on the host.
    public var useMosh: Bool

    public init(id: UUID = UUID(),
                alias: String,
                hostname: String,
                port: Int = 22,
                username: String,
                auth: AuthMethod = .password,
                useMosh: Bool = false) {
        self.id = id
        self.alias = alias
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.useMosh = useMosh
    }

    /// A display string like `matt@example.com:22`.
    public var connectionSummary: String {
        "\(username)@\(hostname)" + (port == 22 ? "" : ":\(port)")
    }
}
