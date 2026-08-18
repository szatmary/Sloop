// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Where each host's command history lives: one JSON file per host, on this
/// device only.
///
/// **Deliberately not synced, and never in the keychain's synchronizable
/// class.** Command lines are full of things nobody meant to store — a token
/// pasted into a `curl`, a password after `mysql -p`, a hostname that says
/// where someone works. The key library syncs because a key is useless without
/// the devices that need it; a history is useful only where it was typed, so
/// the cheapest privacy answer is the right one. `forget(host:)` deletes the
/// file outright, which is what "clear history" has to mean to be worth
/// offering.
///
/// A file that can't be read is replaced rather than moved aside, unlike
/// `HostStore` and `KnownHostsStore`: those hold the only copy of something the
/// user typed and can't reconstruct. This holds a convenience that rebuilds
/// itself from ordinary use, and keeping a corrupt one around would mean
/// suggestions stayed broken until someone noticed a file they never knew
/// existed.
public final class CommandHistoryStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let support = (try? fileManager.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = support.appendingPathComponent("command-history", isDirectory: true)
        }
    }

    /// The history for a host, or an empty one when there is nothing readable.
    public func history(for hostID: UUID) -> CommandHistory {
        guard let data = try? Data(contentsOf: url(for: hostID)),
              let history = try? JSONDecoder().decode(CommandHistory.self, from: data) else {
            return CommandHistory()
        }
        return history
    }

    public func save(_ history: CommandHistory, for hostID: UUID) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(history)
        try data.write(to: url(for: hostID), options: .atomic)
    }

    /// Delete a host's history. Absent is success: the point is that it's gone.
    public func forget(host hostID: UUID) throws {
        let url = url(for: hostID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Delete every host's history. What "clear command history" has to mean
    /// when the user doesn't think in terms of which host learned what.
    public func forgetEverything() throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func url(for hostID: UUID) -> URL {
        directory.appendingPathComponent("\(hostID.uuidString).json")
    }
}
