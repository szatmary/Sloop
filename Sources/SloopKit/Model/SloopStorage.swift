// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Where Sloop's shared state lives, and how it got there.
///
/// The File Provider extension is a separate process that runs while the app
/// does not. Anything both must agree on — the host list, the known-hosts
/// database, each domain's item index — has to sit in the App Group container
/// rather than either process's private one.
///
/// This type owns only the *locations* and the one-time move into them. The
/// stores themselves stay ignorant of containers: `HostStore` is "persistence
/// only, no networking, no secrets" and gains nothing from knowing which
/// sandbox it is in.
public enum SloopStorage {
    /// Must match the App Group in both targets' entitlements.
    public static let appGroupIdentifier = "group.org.szatmary.sloop"

    public enum StorageError: Error, LocalizedError {
        case appGroupUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .appGroupUnavailable(let identifier):
                return "Sloop couldn't open its shared App Group container "
                    + "(\(identifier)). Its saved hosts and host keys live there, and the "
                    + "Files integration reads them from there, so neither can be reached. "
                    + "This normally means the build isn't signed with the App Group "
                    + "entitlement."
            }
        }
    }

    /// Which tsnet node's state — the app's, or the extension's.
    ///
    /// They are separate devices on the tailnet and must never share a
    /// directory. Two processes running one node key means the control plane
    /// sees a single device flapping between two endpoints, which breaks both.
    public enum TailnetRole: String {
        case app = "tailnet"
        case fileProvider = "tailnet-files"
    }

    /// The App Group container, or why it isn't reachable.
    ///
    /// Throws rather than falling back to a private directory. A fallback here
    /// would be invisible and expensive: the app would quietly read a
    /// different host list than the extension, so hosts saved in one would look
    /// deleted in the other, and the user would be told nothing.
    public static func sharedDirectory(appGroup: String = appGroupIdentifier,
                                       fileManager: FileManager = .default) throws -> URL {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup) else {
            throw StorageError.appGroupUnavailable(appGroup)
        }
        let directory = container.appendingPathComponent("Sloop", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func hostsFile(in directory: URL) -> URL {
        directory.appendingPathComponent("sloop-hosts.json")
    }

    public static func knownHostsFile(in directory: URL) -> URL {
        directory.appendingPathComponent("sloop-known-hosts.json")
    }

    /// The `SFTPItemIndex` for one File Provider domain. One per host, because
    /// identifiers are only meaningful within the domain that minted them.
    public static func itemIndexFile(forDomain domain: UUID, in directory: URL) -> URL {
        directory
            .appendingPathComponent("fileprovider", isDirectory: true)
            .appendingPathComponent(domain.uuidString, isDirectory: true)
            .appendingPathComponent("items.json")
    }

    public static func tailnetStateDirectory(role: TailnetRole, in directory: URL,
                                             fileManager: FileManager = .default) throws -> URL {
        let state = directory.appendingPathComponent(role.rawValue, isDirectory: true)
        try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
        return state
    }

    /// The app-private directory hosts and known-hosts lived in before the App
    /// Group existed. Only the app has one; the extension has nothing to
    /// migrate.
    public static func legacyApplicationSupportDirectory(
        fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: true)
    }

    /// Moves a pre-App-Group file into the shared container, once.
    ///
    /// **A byte copy, deliberately.** `HostStore` and `KnownHostsStore` both
    /// carry records this build cannot parse through a rewrite verbatim, so a
    /// host written by a newer build survives an older one. Migrating by
    /// decoding and re-encoding would route the user's only copy through this
    /// build's decoder and quietly drop exactly those records — defeating, at
    /// the one moment it matters most, the protection both stores were built
    /// around.
    ///
    /// **Never overwrites.** If the shared file already exists the migration
    /// has run; copying again would discard everything saved since.
    ///
    /// **Leaves the original.** One stale file is a small price for the user
    /// having a pre-migration copy if any of this went wrong.
    ///
    /// - Returns: whether anything was copied.
    @discardableResult
    public static func migrateLegacyFile(from legacy: URL, to shared: URL,
                                         fileManager: FileManager = .default) throws -> Bool {
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: shared.path) else { return false }
        try fileManager.createDirectory(at: shared.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.copyItem(at: legacy, to: shared)
        return true
    }
}
