// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A remote filesystem, as the File Provider layer sees it.
///
/// This is the `Transport` trick one subsystem over: the whole File Provider
/// extension is written against this protocol, so the enumerators, the item
/// index, and every create/modify/delete path are exercised against
/// `InMemorySFTPClient` — no server, no simulator, on Linux CI. `libssh2` sits
/// behind one conformance in `SloopSSH`, which is the only part that cannot be
/// tested that way.
///
/// **Blocking, by design.** Every method runs to completion on the calling
/// thread. libssh2 sessions are not thread-safe and the File Provider system
/// already calls the extension from its own queues with its own concurrency
/// limits; layering `async` on top would add a second scheduler over a resource
/// that must be serialized anyway. Callers own the queue.
///
/// Paths are absolute and are normalized by the implementation — see
/// `RemotePath`.
public protocol SFTPClient: AnyObject {
    /// Directory entries, excluding `.` and `..`.
    func list(_ path: String) throws -> [SFTPEntry]

    /// Attributes for one item. Follows symlinks: Files.app has no symlink
    /// concept, so an item is presented as whatever it resolves to, and a
    /// broken link fails here rather than appearing as a lie in the listing.
    func stat(_ path: String) throws -> SFTPEntry

    /// Downloads `path` into the file at `destination`, which the caller owns.
    ///
    /// Streams. The extension runs under a memory cap and users have
    /// multi-gigabyte files; an implementation that buffers the whole body is a
    /// jetsam kill, not a slow download. `progress` receives
    /// (bytesTransferred, totalBytes) and may be called from the calling thread
    /// as often as once per chunk.
    func read(_ path: String, into destination: URL,
              progress: (Int64, Int64) -> Void) throws

    /// Uploads the file at `source` to `path`, replacing it if it exists.
    /// Streams, for the same reason as `read`.
    func write(_ source: URL, to path: String,
               progress: (Int64, Int64) -> Void) throws

    func makeDirectory(_ path: String) throws

    /// Removes a file, an empty directory, or a symlink. A non-empty directory
    /// fails with `.directoryNotEmpty` rather than recursing — the File
    /// Provider system asks for deletions item by item, and a silent recursive
    /// delete here would destroy data the system never asked to remove.
    func remove(_ path: String) throws

    /// Renames or moves. Fails with `.alreadyExists` rather than clobbering.
    func rename(_ path: String, to destination: String) throws

    /// The directory a session starts in — the user's home on nearly every
    /// server. `SSHHost.filesRootPath` overrides it when set.
    func defaultDirectory() throws -> String

    /// Releases the connection. Callers invoke it when they are torn down; the
    /// File Provider system does exactly that, at times of its own choosing.
    func close()
}

public extension SFTPClient {
    /// A client with nothing to release. Not a silent fallback — an in-memory
    /// tree genuinely holds no socket, and forcing it to declare an empty
    /// method would be ceremony rather than safety.
    func close() {}

    /// Removes `path` and everything beneath it, depth first.
    ///
    /// Only for the case where the File Provider system explicitly asks
    /// (`NSFileProviderDeleteItemOptions.recursive`); `remove` stays
    /// non-recursive so an ordinary delete cannot take a subtree with it.
    ///
    /// SFTP has no recursive delete, so this is a client-side walk — written
    /// once here rather than in each conformance, since it needs nothing but
    /// `list` and `remove`.
    func removeRecursively(_ path: String) throws {
        let entry = try stat(path)
        if entry.isDirectory {
            for child in try list(path) {
                try removeRecursively(child.path)
            }
        }
        try remove(path)
    }
}

/// An in-memory remote filesystem.
///
/// Ships in SloopKit rather than a test target for the same reason
/// `InMemoryAccessTokenStore` does: the conformance is needed by tests in
/// *both* the SloopKit and the app-side bundles, and a double duplicated across
/// two targets drifts until the two disagree about what the real thing does.
///
/// It enforces the parts of POSIX semantics the File Provider layer depends on
/// — a rename carries its subtree, a non-empty directory refuses to be removed,
/// a file cannot be listed — because a double that is more permissive than the
/// server turns a server-side failure into an untested code path.
public final class InMemorySFTPClient: SFTPClient, @unchecked Sendable {
    private struct Node {
        var kind: SFTPEntry.Kind
        var contents: Data
        var modified: Date
        var mode: UInt32
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private let home: String

    /// Counts calls, so tests can assert that a cache actually spared a round
    /// trip rather than merely producing the right answer.
    public private(set) var listCount = 0
    public private(set) var statCount = 0

    public init(home: String = "/home/matt") {
        self.home = RemotePath.normalize(home)
        nodes["/"] = Node(kind: .directory, contents: Data(),
                          modified: Date(timeIntervalSince1970: 0), mode: 0o040_755)
        var walked = ""
        for segment in self.home.split(separator: "/") {
            walked += "/" + segment
            nodes[walked] = Node(kind: .directory, contents: Data(),
                                 modified: Date(timeIntervalSince1970: 0), mode: 0o040_755)
        }
    }

    // MARK: - Test fixture helpers

    /// Creates a file and every directory above it.
    public func addFile(_ path: String, contents: Data = Data(),
                        modified: Date = Date(timeIntervalSince1970: 0),
                        mode: UInt32 = 0o100_644) {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        makeParents(of: path)
        nodes[path] = Node(kind: .file, contents: contents, modified: modified, mode: mode)
    }

    public func addDirectory(_ path: String, mode: UInt32 = 0o040_755) {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        makeParents(of: path)
        nodes[path] = Node(kind: .directory, contents: Data(),
                           modified: Date(timeIntervalSince1970: 0), mode: mode)
    }

    public func exists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return nodes[RemotePath.normalize(path)] != nil
    }

    public func contents(of path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return nodes[RemotePath.normalize(path)]?.contents
    }

    /// Rewrites an existing file the way another user with a shell would, so
    /// tests can drive the change-detection path.
    public func touch(_ path: String, contents: Data, modified: Date) {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        guard var node = nodes[path] else { return }
        node.contents = contents
        node.modified = modified
        nodes[path] = node
    }

    private func makeParents(of path: String) {
        var walked = ""
        for segment in RemotePath.parent(path).split(separator: "/") {
            walked += "/" + segment
            if nodes[walked] == nil {
                nodes[walked] = Node(kind: .directory, contents: Data(),
                                     modified: Date(timeIntervalSince1970: 0),
                                     mode: 0o040_755)
            }
        }
    }

    private func entry(_ path: String, _ node: Node) -> SFTPEntry {
        SFTPEntry(path: path, size: Int64(node.contents.count),
                  modified: node.modified, mode: node.mode)
    }

    // MARK: - SFTPClient

    public func list(_ path: String) throws -> [SFTPEntry] {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        listCount += 1
        guard let node = nodes[path] else { throw SFTPError.noSuchFile(path) }
        guard node.kind == .directory else { throw SFTPError.notADirectory(path) }
        return nodes
            .filter { RemotePath.parent($0.key) == path && $0.key != path }
            .map { entry($0.key, $0.value) }
            .sorted { $0.path < $1.path }
    }

    public func stat(_ path: String) throws -> SFTPEntry {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        statCount += 1
        guard let node = nodes[path] else { throw SFTPError.noSuchFile(path) }
        return entry(path, node)
    }

    public func read(_ path: String, into destination: URL,
                     progress: (Int64, Int64) -> Void) throws {
        let path = RemotePath.normalize(path)
        lock.lock()
        guard let node = nodes[path] else { lock.unlock(); throw SFTPError.noSuchFile(path) }
        guard node.kind != .directory else { lock.unlock(); throw SFTPError.isADirectory(path) }
        let contents = node.contents
        lock.unlock()
        try contents.write(to: destination)
        progress(Int64(contents.count), Int64(contents.count))
    }

    public func write(_ source: URL, to path: String,
                      progress: (Int64, Int64) -> Void) throws {
        let path = RemotePath.normalize(path)
        let data = try Data(contentsOf: source)
        lock.lock(); defer { lock.unlock() }
        guard nodes[RemotePath.parent(path)]?.kind == .directory else {
            throw SFTPError.noSuchFile(RemotePath.parent(path))
        }
        if nodes[path]?.kind == .directory { throw SFTPError.isADirectory(path) }
        nodes[path] = Node(kind: .file, contents: data, modified: Date(), mode: 0o100_644)
        progress(Int64(data.count), Int64(data.count))
    }

    public func makeDirectory(_ path: String) throws {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        if nodes[path] != nil { throw SFTPError.alreadyExists(path) }
        guard nodes[RemotePath.parent(path)]?.kind == .directory else {
            throw SFTPError.noSuchFile(RemotePath.parent(path))
        }
        nodes[path] = Node(kind: .directory, contents: Data(), modified: Date(),
                           mode: 0o040_755)
    }

    public func remove(_ path: String) throws {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        guard let node = nodes[path] else { throw SFTPError.noSuchFile(path) }
        if node.kind == .directory,
           nodes.keys.contains(where: { RemotePath.isDescendant($0, of: path) }) {
            throw SFTPError.directoryNotEmpty(path)
        }
        nodes[path] = nil
    }

    public func rename(_ path: String, to destination: String) throws {
        let path = RemotePath.normalize(path)
        let destination = RemotePath.normalize(destination)
        lock.lock(); defer { lock.unlock() }
        guard nodes[path] != nil else { throw SFTPError.noSuchFile(path) }
        if nodes[destination] != nil { throw SFTPError.alreadyExists(destination) }
        guard nodes[RemotePath.parent(destination)]?.kind == .directory else {
            throw SFTPError.noSuchFile(RemotePath.parent(destination))
        }
        for key in nodes.keys {
            guard let moved = RemotePath.reparent(key, from: path, to: destination)
            else { continue }
            nodes[moved] = nodes[key]
            nodes[key] = nil
        }
    }

    public func defaultDirectory() throws -> String { home }
}
