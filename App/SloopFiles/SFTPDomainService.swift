// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import FileProvider
import SloopKit
import SloopSSH

/// Everything one published host needs, resolved from its File Provider domain.
///
/// A domain's identifier *is* the host's UUID, so this is where the extension
/// turns "the system is asking about domain X" back into a host, a credential,
/// an SFTP connection, and the item index that gives its files stable
/// identifiers.
///
/// **One serial queue owns the connection.** SFTP calls block and a libssh2
/// session must not be driven by two threads. The system calls the extension
/// concurrently, so every operation is funnelled here; `Progress` and the
/// completion handlers are what keep that invisible to the caller.
///
/// **The connection is opened lazily and kept.** The extension process is
/// started and killed by the system at its own discretion, sometimes for a
/// single `item(for:)`. Reconnecting per operation would put a full TCP
/// handshake, key exchange and authentication in front of every directory tap.
final class SFTPDomainService {
    /// Why an operation could not even be attempted. Distinct from `SFTPError`,
    /// which means the server answered and said no.
    enum ServiceError: Error, LocalizedError {
        case noSuchHost(UUID)
        case notPublished(String)
        case noCredential(String)
        case unknownIdentifier(NSFileProviderItemIdentifier)
        /// The system would not hand out a manager for this domain — it has
        /// been removed, or the extension is running against a domain the
        /// system no longer knows.
        case domainUnavailable

        var errorDescription: String? {
            switch self {
            case .noSuchHost:
                return "This host no longer exists in Sloop. Remove this location from Files."
            case .notPublished(let alias):
                return "\(alias) is no longer shared with Files. Turn \"Show in Files\" back on in Sloop."
            case .noCredential(let alias):
                return "Sloop has no saved password or key for \(alias). Open Sloop and add one."
            case .unknownIdentifier:
                return "Files asked for an item Sloop no longer recognizes. Pull to refresh."
            case .domainUnavailable:
                return "This location is no longer registered with Files. Reopen Sloop."
            }
        }
    }

    let domain: NSFileProviderDomain
    private let queue = DispatchQueue(label: "org.szatmary.sloop.fileprovider.sftp")

    private let host: SSHHost
    private let index: SFTPItemIndex
    private let client: SFTPClient

    /// Resolved once, on first use: the server's default directory unless the
    /// host names its own root.
    private var resolvedRoot: String?

    init(domain: NSFileProviderDomain) throws {
        self.domain = domain

        guard let hostID = UUID(uuidString: domain.identifier.rawValue) else {
            throw ServiceError.unknownIdentifier(
                NSFileProviderItemIdentifier(domain.identifier.rawValue))
        }

        let shared = try SloopStorage.sharedDirectory()
        let hosts = HostStore(fileURL: SloopStorage.hostsFile(in: shared))
        guard let host = hosts.hosts.first(where: { $0.id == hostID }) else {
            throw ServiceError.noSuchHost(hostID)
        }
        // The toggle is the user's statement of intent, and the system can keep
        // a domain around after it is turned off. Honour the host file, not the
        // domain's continued existence.
        guard host.showsInFiles else { throw ServiceError.notPublished(host.alias) }
        self.host = host

        index = SFTPItemIndex(
            fileURL: SloopStorage.itemIndexFile(forDomain: hostID, in: shared))

        let credentials = KeychainCredentialStore()
        let keys = KeychainKeyStore()
        guard let credential = try KeyLibrary.credential(for: host, keys: keys,
                                                         credentials: credentials) else {
            throw ServiceError.noCredential(host.alias)
        }

        client = try SFTPClientFactory.sftp(
            host: host,
            credential: credential,
            knownHosts: KnownHostsStore(fileURL: SloopStorage.knownHostsFile(in: shared)),
            // Never trust-on-first-use here: this process cannot ask anyone.
            hostKeyVerifier: StrictHostKeyVerifier(),
            accessTokens: KeychainAccessTokenStore(),
            tailnetRole: .fileProvider,
            authorizationPresenter: NoAuthorizationPresenter())
    }

    // MARK: - Running work

    /// Runs `body` on the connection's queue and hands the result back.
    ///
    /// Every entry point goes through this, so the serialization guarantee is
    /// structural rather than a convention each method has to remember.
    func perform<T>(_ body: @escaping (SFTPClient, SFTPItemIndex) throws -> T,
                    completion: @escaping (Result<T, Error>) -> Void) {
        queue.async { [client, index] in
            do {
                completion(.success(try body(client, index)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// A scratch file on the volume the system expects.
    ///
    /// `NSFileProviderManager.temporaryDirectoryURL()` is guaranteed to sit on
    /// the same volume as the user-visible URL, which is what lets the system
    /// clone or move the downloaded file into place instead of copying it —
    /// and what `fetchContents` documents as a requirement.
    /// `FileManager.default.temporaryDirectory` carries no such guarantee.
    func temporaryFileURL() throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw ServiceError.domainUnavailable
        }
        return try manager.temporaryDirectoryURL()
            .appendingPathComponent(UUID().uuidString)
    }

    func invalidate() {
        queue.sync {
            try? index.save()
            client.close()
        }
    }

    // MARK: - Paths and identifiers

    /// The directory this domain is rooted at.
    ///
    /// `filesRootPath` when the host names one, otherwise whatever the server
    /// drops a session into — the same place a shell starts, which is what
    /// someone tapping their host in Files.app expects to see.
    func root(_ client: SFTPClient) throws -> String {
        if let resolvedRoot { return resolvedRoot }
        let root = try host.trimmedFilesRootPath ?? client.defaultDirectory()
        resolvedRoot = root
        return root
    }

    /// The remote path an identifier names.
    func path(for identifier: NSFileProviderItemIdentifier,
              _ client: SFTPClient, _ index: SFTPItemIndex) throws -> String {
        if identifier == .rootContainer || identifier == .trashContainer {
            return try root(client)
        }
        guard let id = UUID(uuidString: identifier.rawValue),
              let path = index.path(for: id) else {
            throw ServiceError.unknownIdentifier(identifier)
        }
        return path
    }

    /// The identifier for a path, minting one if it is new. The domain root
    /// always answers `.rootContainer`, which the system requires.
    func identifier(for path: String, _ client: SFTPClient,
                    _ index: SFTPItemIndex) throws -> NSFileProviderItemIdentifier {
        let path = RemotePath.normalize(path)
        if path == (try root(client)) { return .rootContainer }
        return NSFileProviderItemIdentifier(index.identifier(for: path).uuidString)
    }

    /// Builds the system's view of one entry.
    ///
    /// `parentIsWritable` is passed in rather than looked up here: an
    /// enumeration builds one item per directory entry and the answer is the
    /// same for all of them, so statting the parent per item would turn one
    /// listing into N+1 round trips.
    func item(for entry: SFTPEntry, _ client: SFTPClient, _ index: SFTPItemIndex,
              parentIsWritable: Bool? = nil) throws -> FileProviderItem {
        FileProviderItem(entry: entry,
                         identifier: try identifier(for: entry.path, client, index),
                         parent: try identifier(for: RemotePath.parent(entry.path),
                                                client, index),
                         parentIsWritable: parentIsWritable)
    }

    /// Tells the system this domain changed, so it re-enumerates rather than
    /// waiting for the user to pull to refresh.
    ///
    /// Called after Sloop's own mutations. Remote changes still surface only on
    /// the next enumeration — SFTP cannot push — but there is no reason for the
    /// extension's *own* writes to wait for that.
    func signalChange() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: .workingSet) { _ in }
    }
}
