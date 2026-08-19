// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import FileProvider
import SloopKit
import SloopSSH

/// Sloop's File Provider extension: one published host, browsable and writable
/// from Files.app, Finder, and any app's open/save panel.
///
/// **A separate process.** It runs while Sloop does not, shares no memory with
/// it, and has no user interface it could ever present. Everything it needs —
/// the host list, known host keys, credentials, Access tokens — comes from the
/// App Group container and shared keychain groups, and everything it cannot do
/// alone becomes an error naming the app.
///
/// The construction failure is deferred rather than thrown from `init`: the
/// system requires the initializer to succeed, and a domain whose host has been
/// deleted, un-published, or lost its credential must still be able to answer
/// requests — with the reason, so Files.app can show it.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let service: SFTPDomainService?
    private let failure: Error?
    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        do {
            service = try SFTPDomainService(domain: domain)
            failure = nil
        } catch {
            service = nil
            failure = error
        }
        super.init()
    }

    func invalidate() {
        service?.invalidate()
    }

    private func requireService() throws -> SFTPDomainService {
        if let service { return service }
        throw failure ?? SFTPDomainService.ServiceError.unknownIdentifier(.rootContainer)
    }

    // MARK: - Items

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let service = try requireService()
            // The root is synthetic — it must always answer with
            // `.rootContainer`, so it never goes to the server for its own
            // identity.
            if identifier == .rootContainer {
                completionHandler(FileProviderRootItem(name: domain.displayName), nil)
                progress.completedUnitCount = 1
                return progress
            }
            service.perform { client, index in
                let path = try service.path(for: identifier, client, index)
                return try service.item(for: try client.stat(path), client, index)
            } completion: { result in
                progress.completedUnitCount = 1
                switch result {
                case .success(let item): completionHandler(item, nil)
                case .failure(let error): completionHandler(nil, FileProviderError.from(error))
                }
            }
        } catch {
            progress.completedUnitCount = 1
            completionHandler(nil, FileProviderError.from(error))
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        // Sloop has no trash. Aliasing it to the domain root, as this did,
        // listed the user's live home directory as Trash — where "Delete
        // Immediately" would act on real files.
        guard containerItemIdentifier != .trashContainer else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                          userInfo: [NSLocalizedDescriptionKey: "Sloop has no trash."])
        }
        do {
            return FileProviderEnumerator(service: try requireService(),
                                          container: containerItemIdentifier)
        } catch {
            // Every other method routes through FileProviderError; this one
            // threw raw, and it is the *first* call made when the user taps the
            // location. An unmapped domain reads as transient, so a host with no
            // credential or an untrusted key was retried indefinitely — a fresh
            // TCP and SSH handshake each time — instead of showing the sign-in
            // affordance that `notAuthenticated` produces.
            throw FileProviderError.from(error)
        }
    }

    // MARK: - Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void)
    -> Progress {
        let progress = Progress(totalUnitCount: 100)
        do {
            let service = try requireService()
            service.perform { client, index in
                let path = try service.path(for: itemIdentifier, client, index)
                // A temporary file the system takes ownership of. Never an
                // in-memory buffer: this extension runs under a memory cap and
                // the files worth reaching for are the large ones.
                //
                // From the provider's own temporary directory, not
                // FileManager's: the system requires the file be on the same
                // volume as the user-visible URL so it can clone or move it
                // atomically, and only this API guarantees that.
                let destination = try service.temporaryFileURL()
                try client.read(path, into: destination) { done, total in
                    guard total > 0 else { return }
                    progress.completedUnitCount = Int64(Double(done) / Double(total) * 100)
                }
                return (destination, try service.item(for: try client.stat(path), client, index))
            } completion: { result in
                switch result {
                case .success(let (url, item)):
                    progress.completedUnitCount = 100
                    completionHandler(url, item, nil)
                case .failure(let error):
                    completionHandler(nil, nil, FileProviderError.from(error))
                }
            }
        } catch {
            completionHandler(nil, nil, FileProviderError.from(error))
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                                  Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        do {
            let service = try requireService()
            // `conforms(to: .directory)`, not `== .folder`. A package — .rtfd,
            // .bundle, any document that is a directory underneath — is not
            // `.folder` but must still be created as one. Treated as a file it
            // became a 0-byte regular file, and every child the system then
            // wrote into it failed against a non-directory.
            let type = itemTemplate.contentType ?? .data
            let isDirectory = type.conforms(to: .directory)
            guard !type.conforms(to: .symbolicLink) else {
                throw SFTPError.unsupported(itemTemplate.filename)
            }
            let name = itemTemplate.filename
            guard RemotePath.isValidName(name) else { throw SFTPError.unsupported(name) }
            let parent = itemTemplate.parentItemIdentifier

            service.perform { client, index in
                let directory = try service.path(for: parent, client, index)
                let path = RemotePath.join(directory, name)
                if isDirectory {
                    try client.makeDirectory(path)
                } else {
                    // No contents means an empty file — Files.app creates one
                    // before writing to it.
                    let source = url ?? Self.emptyTemporaryFile()
                    try client.write(source, to: path) { done, total in
                        guard total > 0 else { return }
                        progress.completedUnitCount = Int64(Double(done) / Double(total) * 100)
                    }
                }
                return try service.item(for: try client.stat(path), client, index)
            } completion: { result in
                progress.completedUnitCount = 100
                switch result {
                case .success(let item):
                    // Sloop's own writes need not wait for the next
                    // enumeration; only remote changes do.
                    service.signalChange()
                    completionHandler(item, [], false, nil)
                case .failure(let error):
                    completionHandler(nil, [], false, FileProviderError.from(error))
                }
            }
        } catch {
            completionHandler(nil, [], false, FileProviderError.from(error))
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields,
                                                  Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        do {
            let service = try requireService()
            let identifier = item.itemIdentifier
            let newName = item.filename
            guard RemotePath.isValidName(newName) else { throw SFTPError.unsupported(newName) }
            let newParent = item.parentItemIdentifier

            service.perform { client, index in
                var path = try service.path(for: identifier, client, index)

                // A rename and a reparent are one SFTP operation. Doing them as
                // two would briefly leave the file under a name the index does
                // not know, and a crash in between would strand it there.
                if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                    let directory = changedFields.contains(.parentItemIdentifier)
                        ? try service.path(for: newParent, client, index)
                        : RemotePath.parent(path)
                    let destination = RemotePath.join(directory, newName)
                    if destination != path {
                        try client.rename(path, to: destination)
                        // Repoint the identifier rather than mint a new one —
                        // the system requires the id to survive this.
                        index.move(from: path, to: destination)
                        path = destination
                    }
                }

                if changedFields.contains(.contents), let newContents {
                    try client.write(newContents, to: path) { done, total in
                        guard total > 0 else { return }
                        progress.completedUnitCount = Int64(Double(done) / Double(total) * 100)
                    }
                }

                // After the write, not between it and the rename: persisting
                // early recorded a move whose content change had not happened,
                // and a process kill in that window left the index describing a
                // state the server was never in.
                try index.save()
                return try service.item(for: try client.stat(path), client, index)
            } completion: { result in
                progress.completedUnitCount = 100
                switch result {
                case .success(let item):
                    // Sloop's own writes need not wait for the next
                    // enumeration; only remote changes do.
                    service.signalChange()
                    completionHandler(item, [], false, nil)
                case .failure(let error):
                    completionHandler(nil, [], false, FileProviderError.from(error))
                }
            }
        } catch {
            completionHandler(nil, [], false, FileProviderError.from(error))
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do {
            let service = try requireService()
            let recursive = options.contains(.recursive)
            service.perform { client, index in
                let path: String
                do {
                    path = try service.path(for: identifier, client, index)
                } catch {
                    // "If the deletion targets an item that is unknown from the
                    // extension because that item may have already been deleted
                    // remotely, then the extension should report a success."
                    // Reporting noSuchItem instead meant a delete of something
                    // already gone could never converge.
                    return
                }
                do {
                    // Recursive only when the system asks. Unasked, a directory
                    // that refuses because it is not empty is the server telling
                    // the truth, and recursing anyway would destroy data nobody
                    // asked to remove.
                    try recursive ? client.removeRecursively(path) : client.remove(path)
                } catch SFTPError.noSuchFile {
                    // Already gone server-side: the caller's intent is satisfied.
                }
                index.forget(path)
                try index.save()
            } completion: { result in
                progress.completedUnitCount = 1
                switch result {
                case .success:
                    service.signalChange()
                    completionHandler(nil)
                case .failure(let error): completionHandler(FileProviderError.from(error))
                }
            }
        } catch {
            progress.completedUnitCount = 1
            completionHandler(FileProviderError.from(error))
        }
        return progress
    }

    private static func emptyTemporaryFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }
}
