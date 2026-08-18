// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A small JSON-file store for saved hosts. Persistence only — no networking,
/// no secrets. Secrets are the keychain's job.
public final class HostStore {
    private let url: URL
    public private(set) var hosts: [SSHHost] = []

    /// - Parameter fileURL: override the storage location (used by tests).
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.url = fileURL
        } else {
            let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.url = dir.appendingPathComponent("sloop-hosts.json")
        }
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: url) else { hosts = []; return }
        hosts = Self.decodeLossy(data)
    }

    /// Decode a host array, skipping elements that fail (e.g. written by a
    /// newer app with a connection method this build doesn't know) instead of
    /// wiping the whole list. Note the trade-off: the next `save()` persists
    /// only what decoded, dropping the skipped entries.
    static func decodeLossy(_ data: Data) -> [SSHHost] {
        struct Lossy: Decodable {
            let host: SSHHost?
            init(from decoder: Decoder) throws { host = try? SSHHost(from: decoder) }
        }
        let wrapped = (try? JSONDecoder().decode([Lossy].self, from: data)) ?? []
        return wrapped.compactMap(\.host)
    }

    public func save() throws {
        let data = try JSONEncoder().encode(hosts)
        try data.write(to: url, options: [.atomic])
    }

    /// Insert a new host or replace the existing one with the same `id`.
    public func upsert(_ host: SSHHost) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        try? save()
    }

    public func remove(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        try? save()
    }
}
