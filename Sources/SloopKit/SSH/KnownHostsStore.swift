import Foundation

/// The result of checking a host key against what we've seen before.
public enum KnownHostStatus: Equatable {
    /// Never connected to this endpoint — trust-on-first-use applies.
    case unknown
    /// Key matches the one we recorded. Safe to proceed.
    case match
    /// Key differs from the recorded one. Possible MITM — refuse.
    case mismatch
}

/// A tiny known-hosts database, keyed by `host:port`.
///
/// Stores the host key type and a base64 fingerprint so we can detect when a
/// server's key changes between connections. Persistence is JSON; inject a
/// `fileURL` in tests. This is deliberately independent of any SSH library so it
/// unit-tests without a Mac.
public final class KnownHostsStore {
    private struct Entry: Codable, Equatable {
        var endpoint: String
        var keyType: String
        var fingerprint: String
    }

    private let url: URL
    private var entries: [Entry]

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.url = fileURL
        } else {
            let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.url = dir.appendingPathComponent("sloop-known-hosts.json")
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        self.entries = (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    public static func endpoint(host: String, port: Int) -> String { "\(host):\(port)" }

    /// Compare an observed key against what we've recorded for this endpoint.
    public func status(endpoint: String, keyType: String, fingerprint: String) -> KnownHostStatus {
        guard let existing = entries.first(where: { $0.endpoint == endpoint }) else {
            return .unknown
        }
        return (existing.keyType == keyType && existing.fingerprint == fingerprint)
            ? .match : .mismatch
    }

    /// The key we currently have on record for an endpoint, if any. Used to show
    /// the user what changed when a key no longer matches.
    public func recorded(endpoint: String) -> (keyType: String, fingerprint: String)? {
        guard let existing = entries.first(where: { $0.endpoint == endpoint }) else { return nil }
        return (existing.keyType, existing.fingerprint)
    }

    /// Record (or replace) the key for an endpoint. Call this after a successful
    /// trust-on-first-use, or when the user explicitly accepts a changed key.
    public func remember(endpoint: String, keyType: String, fingerprint: String) {
        entries.removeAll { $0.endpoint == endpoint }
        entries.append(Entry(endpoint: endpoint, keyType: keyType, fingerprint: fingerprint))
        try? persist()
    }

    public func forget(endpoint: String) {
        entries.removeAll { $0.endpoint == endpoint }
        try? persist()
    }

    private func persist() throws {
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic])
    }
}
