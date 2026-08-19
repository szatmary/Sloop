// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// What changed in one directory between two listings.
public struct SFTPDirectoryChanges: Equatable, Sendable {
    public var added: [SFTPEntry] = []
    public var updated: [SFTPEntry] = []
    /// Items gone from the server. Reported by identifier because the path no
    /// longer names anything — the system needs the id it was given before.
    public var removedIdentifiers: [UUID] = []

    public var isEmpty: Bool {
        added.isEmpty && updated.isEmpty && removedIdentifiers.isEmpty
    }
}

/// The identity and change-detection layer between SFTP and a File Provider
/// replica. One index per domain; one domain per host.
///
/// **Why it exists.** `NSFileProviderItemIdentifier` must not change when an
/// item is renamed or moved. SFTP has only paths, and a path *does* change on
/// rename, so using the path as the identifier is wrong in a way that surfaces
/// later as a corrupted replica rather than as a build error. This index mints
/// a stable UUID per path and rewrites the path underneath it.
///
/// **Why it also holds snapshots.** SFTP has no change feed, so
/// `enumerateChanges(from:)` cannot be event-driven. Storing each listed
/// directory's last-seen attributes lets a fresh listing be diffed against what
/// the replica was last told, which is the closest thing to change tracking the
/// protocol allows. The consequence is documented rather than hidden: a change
/// made by someone else over SSH surfaces on the next enumeration, not the
/// moment it happens.
///
/// **Losing it is recoverable.** A missing or corrupt file starts empty;
/// identifiers are re-minted and the caller repairs the replica with
/// `reimportItems(below:)`. That is strictly better than refusing to load,
/// which would strand the domain with no way back.
///
/// Access is serialized: the File Provider system calls an extension from
/// several queues at once, and this is shared mutable state.
public final class SFTPItemIndex: @unchecked Sendable {
    /// The attributes a change is detected from. Not the whole `SFTPEntry`:
    /// this is compared on every enumeration and persisted on every save, and
    /// it should say exactly what "changed" means rather than inheriting
    /// whatever fields the entry grows later.
    private struct Snapshot: Codable, Equatable {
        var size: Int64
        var modified: Date
        var mode: UInt32

        init(_ entry: SFTPEntry) {
            size = entry.size
            modified = entry.modified
            mode = entry.mode
        }
    }

    private struct Persisted: Codable {
        var anchor: UInt64
        var pathsByID: [UUID: String]
        var snapshots: [String: [String: Snapshot]]
    }

    private let url: URL
    private let lock = NSLock()

    private var pathsByID: [UUID: String] = [:]
    private var idsByPath: [String: UUID] = [:]
    /// directory path → (child path → last-seen attributes)
    private var snapshots: [String: [String: Snapshot]] = [:]
    private var _anchor: UInt64 = 0

    public init(fileURL: URL) {
        url = fileURL
        load()
    }

    /// The current sync anchor. Advances only when something actually changed,
    /// so a no-op enumeration doesn't invalidate the system's cursor and force
    /// a pointless full re-enumeration.
    public var anchor: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _anchor
    }

    // MARK: - Identity

    /// The stable identifier for `path`, minting one if this is the first sight
    /// of it.
    public func identifier(for path: String) -> UUID {
        lock.lock(); defer { lock.unlock() }
        return identifierLocked(for: RemotePath.normalize(path))
    }

    private func identifierLocked(for path: String) -> UUID {
        if let existing = idsByPath[path] { return existing }
        let minted = UUID()
        idsByPath[path] = minted
        pathsByID[minted] = path
        return minted
    }

    /// Where `id` currently points, or nil if it was never minted or has been
    /// forgotten.
    public func path(for id: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pathsByID[id]
    }

    /// Repoints `from` — and everything beneath it — at `to`, preserving every
    /// identifier. This is what makes a rename a rename rather than a delete
    /// and a create.
    public func move(from: String, to destination: String) {
        let from = RemotePath.normalize(from)
        let destination = RemotePath.normalize(destination)
        lock.lock(); defer { lock.unlock() }

        // Anything already sitting at the destination is gone as far as the
        // index is concerned — the server just overwrote or replaced it. Its
        // identifier has to be dropped *before* the repoint, or two ids end up
        // naming one path: `pathsByID` keeps both while `idsByPath` can only
        // record one, and the pair never resolves. That state is also fatal
        // rather than merely wrong, because `load` rebuilds `idsByPath` with
        // `Dictionary(uniqueKeysWithValues:)`, which traps on the duplicate —
        // inside `init`, where no `try?` can catch it. Saving it once made the
        // extension crash on every launch for that domain.
        forgetLocked(destination)

        var moved = false
        for (id, path) in pathsByID {
            guard let repointed = RemotePath.reparent(path, from: from, to: destination)
            else { continue }
            idsByPath[path] = nil
            pathsByID[id] = repointed
            idsByPath[repointed] = id
            moved = true
        }

        for (directory, children) in snapshots {
            guard let repointedDirectory = RemotePath.reparent(directory, from: from,
                                                               to: destination)
            else { continue }
            snapshots[directory] = nil
            snapshots[repointedDirectory] = Dictionary(
                uniqueKeysWithValues: children.compactMap { child, snapshot in
                    RemotePath.reparent(child, from: from, to: destination)
                        .map { ($0, snapshot) }
                })
            moved = true
        }

        // The source parent no longer holds that name. The destination parent's
        // snapshot is left alone: dropping the *whole* listing there would
        // discard every other entry's last-seen state, so anything deleted on
        // the server since the last enumeration could never be diffed again and
        // its identifier would never be reported removed. The moved item is
        // simply absent from that snapshot, which the next listing reports as an
        // addition — the correct answer.
        snapshots[RemotePath.parent(from)]?[from] = nil
        snapshots[RemotePath.parent(destination)]?[destination] = nil

        if moved { _anchor += 1 }
    }

    /// Drops `path` and its whole subtree — what a delete means to the index.
    public func forget(_ path: String) {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        forgetLocked(path)
        _anchor += 1
    }

    private func forgetLocked(_ path: String) {
        for (id, known) in pathsByID where known == path || RemotePath.isDescendant(known, of: path) {
            pathsByID[id] = nil
            idsByPath[known] = nil
        }
        for directory in snapshots.keys
        where directory == path || RemotePath.isDescendant(directory, of: path) {
            snapshots[directory] = nil
        }
        snapshots[RemotePath.parent(path)]?[path] = nil
    }

    // MARK: - Change detection

    /// Records `listing` as the current state of `directory` and returns what
    /// changed since the last time it was recorded.
    ///
    /// An item whose *kind* changed is reported as a removal plus an addition
    /// under a fresh identifier, never as an update: the system cannot turn a
    /// file into a directory in place, and telling it to would leave the
    /// replica describing something the server does not have.
    @discardableResult
    public func apply(listing: [SFTPEntry], to directory: String) -> SFTPDirectoryChanges {
        let directory = RemotePath.normalize(directory)
        lock.lock(); defer { lock.unlock() }

        let previous = snapshots[directory] ?? [:]
        var current: [String: Snapshot] = [:]
        var changes = SFTPDirectoryChanges()

        for entry in listing {
            current[entry.path] = Snapshot(entry)
            guard let was = previous[entry.path] else {
                _ = identifierLocked(for: entry.path)
                changes.added.append(entry)
                continue
            }
            if SFTPEntry.Kind(posixMode: was.mode) != entry.kind {
                if let staleID = idsByPath[entry.path] {
                    changes.removedIdentifiers.append(staleID)
                    pathsByID[staleID] = nil
                    idsByPath[entry.path] = nil
                }
                _ = identifierLocked(for: entry.path)
                changes.added.append(entry)
            } else if was != Snapshot(entry) {
                changes.updated.append(entry)
            }
        }

        for goneParent in previous.keys where current[goneParent] == nil {
            if let goneID = idsByPath[goneParent] {
                changes.removedIdentifiers.append(goneID)
            }
            forgetLocked(goneParent)
        }

        snapshots[directory] = current
        if !changes.isEmpty { _anchor += 1 }
        return changes
    }

    /// The paths last recorded for `directory`. For tests and diagnostics.
    public func snapshotPaths(of directory: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (snapshots[RemotePath.normalize(directory)] ?? [:]).keys.sorted()
    }

    // MARK: - Persistence

    public func save() throws {
        lock.lock()
        let state = Persisted(anchor: _anchor, pathsByID: pathsByID, snapshots: snapshots)
        lock.unlock()

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        _anchor = state.anchor
        snapshots = state.snapshots

        // `uniqueKeysWithValues` would trap on two identifiers naming one path,
        // and it would trap *inside init*, where the `try?` above cannot catch
        // it — turning a recoverable bad file into a crash on every launch. The
        // producer of that state is fixed (see `move`), but this is the last
        // line of defense and it should fail soft: keep one identifier per path
        // and drop the rest, which costs the replica a re-import rather than the
        // domain's ability to start at all.
        idsByPath = [:]
        pathsByID = [:]
        for (id, path) in state.pathsByID.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard idsByPath[path] == nil else { continue }
            idsByPath[path] = id
            pathsByID[id] = path
        }
    }
}
