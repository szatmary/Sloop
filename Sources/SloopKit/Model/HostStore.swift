import Foundation

/// A small JSON-file store for saved hosts. Persistence only — no networking,
/// no secrets. Secrets are the keychain's job.
public final class HostStore {
    private let url: URL
    public private(set) var hosts: [Host] = []

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
        hosts = (try? JSONDecoder().decode([Host].self, from: data)) ?? []
    }

    public func save() throws {
        let data = try JSONEncoder().encode(hosts)
        try data.write(to: url, options: [.atomic])
    }

    /// Insert a new host or replace the existing one with the same `id`.
    public func upsert(_ host: Host) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        try? save()
    }

    public func remove(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        try? save()
    }
}
