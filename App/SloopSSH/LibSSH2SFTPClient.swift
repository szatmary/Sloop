// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// The SFTP subsystem on a `LibSSH2Connection` — the one conformance of
// `SFTPClient` that talks to a real server. Everything above it is written
// against the protocol and tested against `InMemorySFTPClient`.
#if canImport(CSSH)
import Foundation
import CSSH
import SloopKit

/// `SFTPClient` over libssh2.
///
/// **Serialized.** A libssh2 session is not thread-safe, and the File Provider
/// system calls an extension from several queues at once. One lock around every
/// operation is not a performance compromise here — the alternative is memory
/// corruption on a session two threads are both driving.
///
/// **Streaming.** Reads and writes move fixed-size chunks between the socket
/// and a file on disk. Nothing buffers a whole file: the extension runs under a
/// memory cap and the files people keep on servers are exactly the ones that
/// exceed it.
final class LibSSH2SFTPClient: SFTPClient, @unchecked Sendable {
    /// 32 KiB. Large enough that per-call overhead disappears against the
    /// window, small enough that a transfer's peak footprint is a rounding
    /// error against the extension's memory limit.
    private static let chunkSize = 32 * 1024

    /// How long a polite shutdown may take before `close()` stops waiting.
    ///
    /// Far more than a live server needs to answer a CLOSE, and far less than
    /// the system waits before deciding the extension has hung.
    private static let shutdownTimeout: TimeInterval = 2

    private let connection: LibSSH2Connection
    private let lock = NSLock()

    private var session: OpaquePointer?
    private var sftp: OpaquePointer?

    /// Set when a failure was transport-level rather than the server saying no.
    ///
    /// The connection is kept for the life of the process, so without this a
    /// dropped link is permanent: the socket dies, every later call fails, and
    /// `openLocked` returns the same dead handle because `sftp` is non-nil.
    /// Files.app reads `ECONNRESET` as transient and retries forever, so the
    /// domain never recovers until the system happens to kill the extension.
    ///
    /// A flag rather than tearing down where the failure is noticed: that code
    /// runs with the lock held and with the caller's file handle still live in
    /// a `defer`, so freeing the session there would deadlock or free memory
    /// about to be used. The next entry point is the safe place.
    ///
    /// `error(on:path:)` is the only writer, because it is the one place that
    /// already has to tell a transport failure from a server refusal.
    private var isBroken = false

    init(host: SSHHost,
         credential: Credential,
         dialer: Dialer,
         knownHosts: KnownHostsStore,
         hostKeyVerifier: HostKeyVerifier) {
        connection = LibSSH2Connection(host: host, credential: credential, dialer: dialer,
                                       knownHosts: knownHosts,
                                       hostKeyVerifier: hostKeyVerifier)
    }

    deinit { close() }

    /// Connects and starts the SFTP subsystem. Safe to call more than once;
    /// the second call is a no-op.
    func open() throws {
        lock.lock(); defer { lock.unlock() }
        try openLocked()
    }

    private func openLocked() throws {
        // A session that died mid-operation is discarded here, where no handle
        // from the failed call is still in scope, and the next few lines redial.
        if isBroken { discardLocked() }
        guard sftp == nil else { return }
        let session = try connection.open()
        self.session = session

        var handle: OpaquePointer?
        while handle == nil {
            handle = libssh2_sftp_init(session)
            if handle == nil {
                guard libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN else {
                    let reason = connection.lastError
                    connection.close()
                    self.session = nil
                    // Not an SFTPError: nothing has been asked of the
                    // filesystem yet. A server with SFTP disabled fails here,
                    // and reporting it as a missing file would send the user
                    // looking for a path instead of at their sshd config.
                    throw SSHError.channelFailure(
                        "couldn't start the SFTP subsystem — \(reason). "
                        + "The server may not have an SFTP subsystem enabled.")
                }
                connection.waitSocket()
            }
        }
        sftp = handle
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if let sftp, !isBroken {
            // Only worth asking politely while the socket is alive, and only
            // for as long as a live peer would take to answer. A link that
            // went away without a FIN — a sleeping laptop, a NAT that dropped
            // the flow — stays writable and simply never replies, so an
            // unbounded EAGAIN loop here has no end. It runs inside the
            // `queue.sync` of `SFTPDomainService.invalidate()`, which is the
            // system waiting for the extension to go away, so wedging here is
            // a hung teardown rather than a slow one.
            let deadline = Date().addingTimeInterval(Self.shutdownTimeout)
            while libssh2_sftp_shutdown(sftp) == LIBSSH2_ERROR_EAGAIN, Date() < deadline {
                connection.waitSocket()
            }
        }
        discardLocked()
    }

    /// Drops the session without talking to the server. Caller holds the lock.
    private func discardLocked() {
        sftp = nil
        session = nil
        isBroken = false
        connection.close()
    }

    // MARK: - SFTPClient

    func list(_ path: String) throws -> [SFTPEntry] {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        let sftp = try subsystem()

        return try withHandle(path, on: sftp, flags: 0, mode: 0,
                              kind: LIBSSH2_SFTP_OPENDIR) { handle in
            var entries: [SFTPEntry] = []
            var name = [CChar](repeating: 0, count: 1024)
            while true {
                var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                let rc = libssh2_sftp_readdir_ex(handle, &name, name.count, nil, 0, &attributes)
                if rc == LIBSSH2_ERROR_EAGAIN { connection.waitSocket(); continue }
                if rc == 0 { break }                                  // end of directory
                guard rc > 0 else { throw error(on: sftp, path: path) }

                let filename = String(cString: name)
                // "." and ".." are the directory itself and its parent. Handing
                // them to the File Provider system would make the replica a
                // cyclic graph, which it will happily follow.
                guard filename != ".", filename != ".." else { continue }
                entries.append(entry(name: filename, in: path, attributes: attributes))
            }
            return entries
        }
    }

    func stat(_ path: String) throws -> SFTPEntry {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        let sftp = try subsystem()
        // LIBSSH2_SFTP_STAT follows symlinks (LSTAT would not). Files.app has
        // no symlink concept, so an item is presented as what it resolves to;
        // a broken link fails here rather than becoming a listing that lies.
        let attributes = try statLocked(path, on: sftp, kind: LIBSSH2_SFTP_STAT)
        return entry(name: RemotePath.name(path), in: RemotePath.parent(path),
                     attributes: attributes)
    }

    func read(_ path: String, into destination: URL,
              progress: (Int64, Int64) -> Void) throws {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        let sftp = try subsystem()

        // nil when the server sent no size: there is then nothing to check the
        // transfer against, and a zero standing in for the absent value would
        // fail every download from such a server.
        let expected = Self.reportedSize(
            of: try statLocked(path, on: sftp, kind: LIBSSH2_SFTP_STAT))

        // The local file is prepared before the remote handle is opened, so a
        // failure here cannot strand one on the server.
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw SFTPError.permissionDenied(destination.path)
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }

        try withHandle(path, on: sftp, flags: UInt(LIBSSH2_FXF_READ), mode: 0,
                       kind: LIBSSH2_SFTP_OPENFILE) { handle in
            var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
            var transferred: Int64 = 0
            while true {
                let n = buffer.withUnsafeMutableBytes { raw in
                    libssh2_sftp_read(handle, raw.bindMemory(to: CChar.self).baseAddress, raw.count)
                }
                if n == Int(LIBSSH2_ERROR_EAGAIN) { connection.waitSocket(); continue }
                if n == 0 { break }                                   // EOF
                guard n > 0 else { throw error(on: sftp, path: path) }

                try file.write(contentsOf: Data(buffer[0..<n]))
                transferred += Int64(n)
                progress(transferred, max(expected ?? transferred, transferred))
            }
            // An EOF short of the file's length is a truncated download, and
            // the bytes that did arrive are a valid file — Files.app would hand
            // the user that short copy as the whole thing.
            try Self.verifyComplete(path: path, expected: expected, transferred: transferred)
        }
    }

    func write(_ source: URL, to path: String,
               progress: (Int64, Int64) -> Void) throws {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        let sftp = try subsystem()

        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        // From the open handle rather than a stat with a `?? 0` default: this
        // is the count the upload is checked against below, and a zero standing
        // in for an unreadable attribute would make every upload look complete.
        let expected = Int64(try file.seekToEnd())
        try file.seek(toOffset: 0)

        let existing = try attributesIfPresent(path, on: sftp)
        if let existing, Self.kind(of: existing) == .directory {
            throw SFTPError.isADirectory(path)
        }

        // Upload beside the target and move it into place, rather than opening
        // the target with LIBSSH2_FXF_TRUNC and streaming into it. TRUNC empties
        // the user's file before the first byte arrives: a dropped link, a full
        // disk, or the system killing the extension halfway through then leaves
        // them with nothing, and no copy anywhere to put back. Nothing below
        // touches the target until the whole file is on the server.
        //
        // Same directory, so the move is a metadata operation on one filesystem
        // rather than a second copy of the bytes. Dot-prefixed, so a leftover
        // from a killed process stays out of the user's way.
        let temporary = RemotePath.join(RemotePath.parent(path),
                                        ".sloop-upload-\(UUID().uuidString)")
        // A move replaces the inode, so the temporary has to be created with the
        // target's own permissions or every save would reset a 0600 file to
        // 0644. The server's umask can still narrow them; it cannot widen them.
        let mode = existing.flatMap(Self.permissions) ?? 0o644

        do {
            // EXCL, not CREAT alone: the name is a fresh UUID, so anything
            // already answering to it is not ours to overwrite.
            try withHandle(temporary, on: sftp,
                           flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT
                                       | LIBSSH2_FXF_EXCL),
                           mode: mode, kind: LIBSSH2_SFTP_OPENFILE) { handle in
                var transferred: Int64 = 0
                while let chunk = try file.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                    var offset = 0
                    while offset < chunk.count {
                        let n = chunk.withUnsafeBytes { raw -> Int in
                            let base = raw.bindMemory(to: CChar.self).baseAddress!
                            return libssh2_sftp_write(handle, base + offset, chunk.count - offset)
                        }
                        if n == Int(LIBSSH2_ERROR_EAGAIN) { connection.waitSocket(); continue }
                        guard n > 0 else { throw error(on: sftp, path: path) }
                        offset += n
                        transferred += Int64(n)
                        progress(transferred, max(expected, transferred))
                    }
                }
                try Self.verifyComplete(path: path, expected: expected, transferred: transferred)
            }

            // What the server *stored*, not what was handed to the socket. The
            // close above is where SFTP flushes, so this is the first moment
            // the answer is authoritative — and the last chance to notice a
            // short file before it is moved over the user's data.
            let stored = try statLocked(temporary, on: sftp, kind: LIBSSH2_SFTP_LSTAT)
            try Self.verifyComplete(path: path, expected: expected,
                                    transferred: Self.reportedSize(of: stored) ?? expected)
        } catch {
            // Nothing outside the temporary has been touched yet, so the target
            // still holds whatever it held before. Drop the half-file rather
            // than leave it hidden in the user's directory.
            discardTemporary(temporary, on: sftp)
            throw error
        }

        // Outside the `catch` on purpose: past this point the temporary can be
        // the only copy of the new contents, so `replace` decides for itself
        // which of its failures are safe to clean up after.
        try replace(path, with: temporary, on: sftp, targetExists: existing != nil)
    }

    func makeDirectory(_ path: String) throws {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        let sftp = try subsystem()
        try perform(path, on: sftp) {
            path.withCString { libssh2_sftp_mkdir_ex(sftp, $0, UInt32(path.utf8.count), 0o755) }
        }
    }

    func remove(_ path: String) throws {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        let sftp = try subsystem()

        // A directory needs rmdir and a file needs unlink, and asking the
        // wrong one produces a status that says nothing useful. One stat
        // decides it. Deliberately no recursion: the File Provider system
        // deletes item by item, and a recursive delete here would destroy data
        // it never asked to remove.
        let attributes = try statLocked(path, on: sftp, kind: LIBSSH2_SFTP_LSTAT)
        // Only trust the mode when the server said it sent one. Absent, the
        // zero-initialized field reads as a regular file, and "assume file" is
        // not the safe default here the way it is for a listing — it picks
        // `unlink` for a directory, which fails for a reason the user cannot
        // act on. Ask outright instead.
        guard Self.permissions(of: attributes) != nil else {
            throw SFTPError.unsupported(path)
        }
        let isDirectory = Self.kind(of: attributes) == .directory

        try perform(path, on: sftp) {
            path.withCString {
                isDirectory
                    ? libssh2_sftp_rmdir_ex(sftp, $0, UInt32(path.utf8.count))
                    : libssh2_sftp_unlink_ex(sftp, $0, UInt32(path.utf8.count))
            }
        }
    }

    func rename(_ path: String, to destination: String) throws {
        let path = RemotePath.normalize(path)
        let destination = RemotePath.normalize(destination)
        lock.lock(); defer { lock.unlock() }
        let sftp = try subsystem()
        // No overwrite flags: a move that silently replaces the file already at
        // the destination is data loss the user never asked for. EEXIST lets
        // Files.app offer its own "keep both" instead. `write` does move its
        // temporary over an existing target, and says why where it does it.
        try perform(destination, on: sftp) {
            path.withCString { from in
                destination.withCString { to in
                    libssh2_sftp_rename_ex(sftp, from, UInt32(path.utf8.count),
                                           to, UInt32(destination.utf8.count), 0)
                }
            }
        }
    }

    func defaultDirectory() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let sftp = try subsystem()

        var target = [CChar](repeating: 0, count: 4096)
        while true {
            let rc = ".".withCString { dot in
                libssh2_sftp_symlink_ex(sftp, dot, 1, &target, UInt32(target.count),
                                        LIBSSH2_SFTP_REALPATH)
            }
            if rc == LIBSSH2_ERROR_EAGAIN { connection.waitSocket(); continue }
            guard rc > 0 else { throw error(on: sftp, path: ".") }
            // Not NUL-terminated by libssh2 — rc is the length.
            return RemotePath.normalize(String(decoding: target[0..<Int(rc)].map { UInt8(bitPattern: $0) },
                                               as: UTF8.self))
        }
    }

    // MARK: - Transfer completeness

    /// Fails when fewer bytes moved than the file holds.
    ///
    /// Nothing in an SFTP data stream carries a length, so a transfer that
    /// stops early yields a shorter file rather than an error — a perfectly
    /// valid file of the wrong size, which is the one failure that can pass for
    /// success all the way to the user.
    ///
    /// `expected` is nil when the server reported no size at all and there is
    /// consequently nothing to compare against. More bytes than expected is a
    /// file that grew while it was being read, not a failure.
    static func verifyComplete(path: String, expected: Int64?, transferred: Int64) throws {
        guard let expected, transferred < expected else { return }
        throw SFTPError.truncated(path, expected: expected, actual: transferred)
    }

    // MARK: - libssh2 plumbing

    private func subsystem() throws -> OpaquePointer {
        try openLocked()
        guard let sftp else {
            throw SSHError.channelFailure("the SFTP session is closed")
        }
        return sftp
    }

    /// Opens a file or directory handle, retrying through EAGAIN.
    private func open(_ path: String, on sftp: OpaquePointer,
                      flags: UInt, mode: Int, kind: Int32) throws -> OpaquePointer {
        while true {
            let handle = path.withCString {
                libssh2_sftp_open_ex(sftp, $0, UInt32(path.utf8.count),
                                     flags, mode, kind)
            }
            if let handle { return handle }
            guard let session,
                  libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN else {
                throw error(on: sftp, path: path)
            }
            connection.waitSocket()
        }
    }

    /// Opens a handle, runs `body`, and closes it whichever way `body` ends.
    ///
    /// The close is not bookkeeping. SFTP flushes on close, so a full disk, an
    /// exceeded quota, or a write-back I/O error on an upload is reported
    /// *there* and nowhere else. Discarding it — which is all a `defer` can do
    /// — is how a file that never landed gets reported to Files.app as a
    /// completed save.
    ///
    /// When `body` itself failed, its error is the specific one and the close
    /// is only cleanup.
    private func withHandle<T>(_ path: String, on sftp: OpaquePointer, flags: UInt,
                               mode: Int, kind: Int32,
                               _ body: (OpaquePointer) throws -> T) throws -> T {
        let handle = try open(path, on: sftp, flags: flags, mode: mode, kind: kind)
        let result: T
        do {
            result = try body(handle)
        } catch {
            // A session already known broken is not asked to close: the CLOSE
            // packet has nowhere to go, and libssh2 frees outstanding handles
            // with the session that `openLocked` discards on the next call.
            if !isBroken { _ = closeHandle(handle) }
            throw error
        }
        guard closeHandle(handle) == 0 else { throw error(on: sftp, path: path) }
        return result
    }

    /// Closes a handle, returning libssh2's status.
    private func closeHandle(_ handle: OpaquePointer) -> Int32 {
        while true {
            let rc = libssh2_sftp_close_handle(handle)
            if rc == LIBSSH2_ERROR_EAGAIN { connection.waitSocket(); continue }
            return rc
        }
    }

    private func statLocked(_ path: String, on sftp: OpaquePointer,
                            kind: Int32) throws -> LIBSSH2_SFTP_ATTRIBUTES {
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        while true {
            let rc = path.withCString {
                libssh2_sftp_stat_ex(sftp, $0, UInt32(path.utf8.count), kind, &attributes)
            }
            if rc == LIBSSH2_ERROR_EAGAIN { connection.waitSocket(); continue }
            guard rc == 0 else { throw error(on: sftp, path: path) }
            return attributes
        }
    }

    /// Attributes for `path`, or nil when nothing is there yet. Only a missing
    /// file is absorbed — every other refusal is still the server's answer.
    private func attributesIfPresent(_ path: String,
                                     on sftp: OpaquePointer) throws -> LIBSSH2_SFTP_ATTRIBUTES? {
        do {
            return try statLocked(path, on: sftp, kind: LIBSSH2_SFTP_LSTAT)
        } catch SFTPError.noSuchFile {
            return nil
        }
    }

    /// Runs an int-returning SFTP call to completion, turning a failure into
    /// the typed error for `path`.
    private func perform(_ path: String, on sftp: OpaquePointer,
                         _ op: () -> Int32) throws {
        while true {
            let rc = op()
            if rc == LIBSSH2_ERROR_EAGAIN { connection.waitSocket(); continue }
            guard rc == 0 else { throw error(on: sftp, path: path) }
            return
        }
    }

    // MARK: - Moving an upload into place

    /// Moves `temporary` onto `path`, replacing whatever is there.
    ///
    /// Three attempts, in decreasing order of atomicity, because SFTP cannot
    /// express "rename over" before protocol version 5 and libssh2 speaks
    /// version 3 — the version OpenSSH serves.
    ///
    /// 1. `posix-rename@openssh.com`, which is `rename(2)` on the server: one
    ///    atomic step in which the target is never absent. Present on every
    ///    OpenSSH server since 4.8, so this is the path nearly every user takes.
    /// 2. Plain rename with the overwrite flags. libssh2 only puts those on the
    ///    wire for a version-5 server; against a version-3 one they are not
    ///    sent at all, so this succeeds only when nothing is in the way.
    /// 3. Unlink the target, then rename. Not atomic: a failure between the two
    ///    leaves the target missing and the bytes under `temporary`. Kept
    ///    anyway, because without it saving over an existing file is impossible
    ///    on a server offering neither of the above — and the window is two
    ///    metadata calls wide, against the whole upload that
    ///    `LIBSSH2_FXF_TRUNC` used to expose.
    ///
    /// Cleaning up `temporary` belongs here rather than to the caller, because
    /// only this method knows whether the target still exists: once step 3 has
    /// unlinked it, `temporary` holds the only copy of the file, and deleting
    /// it would finish the job the old TRUNC used to start.
    private func replace(_ path: String, with temporary: String, on sftp: OpaquePointer,
                         targetExists: Bool) throws {
        if renameStatus(temporary, to: path, on: sftp, posix: true) == 0 { return }
        if renameStatus(temporary, to: path, on: sftp, posix: false) == 0 { return }
        // Nothing to clear out of the way, so whatever refused is a real
        // failure: unlinking a target that was never there would only replace
        // the server's reason with ENOENT. The target is untouched, so the
        // upload is the only thing left to undo.
        guard targetExists else {
            discardTemporary(temporary, on: sftp)
            throw error(on: sftp, path: path)
        }

        do {
            try perform(path, on: sftp) {
                path.withCString { libssh2_sftp_unlink_ex(sftp, $0, UInt32(path.utf8.count)) }
            }
        } catch {
            discardTemporary(temporary, on: sftp)
            throw error
        }

        guard renameStatus(temporary, to: path, on: sftp, posix: false) == 0 else {
            // The target is gone and `temporary` is the only copy of what was
            // meant to replace it, so it stays. Reported against the
            // temporary's path rather than the target's: it is the one thing
            // the user can still recover, and an error naming a file that no
            // longer exists would not say where to look for it.
            throw error(on: sftp, path: temporary)
        }
    }

    /// Runs a rename to completion and hands back libssh2's status
    /// unclassified: the caller is trying alternatives, and a server that
    /// refuses one of them is describing a capability gap rather than a failure
    /// worth reporting.
    private func renameStatus(_ path: String, to destination: String,
                              on sftp: OpaquePointer, posix: Bool) -> Int32 {
        connection.retry {
            path.withCString { from in
                destination.withCString { to in
                    posix
                        ? libssh2_sftp_posix_rename_ex(sftp, from, path.utf8.count,
                                                       to, destination.utf8.count)
                        : libssh2_sftp_rename_ex(sftp, from, UInt32(path.utf8.count),
                                                 to, UInt32(destination.utf8.count),
                                                 Int(LIBSSH2_SFTP_RENAME_OVERWRITE
                                                     | LIBSSH2_SFTP_RENAME_ATOMIC
                                                     | LIBSSH2_SFTP_RENAME_NATIVE))
                }
            }
        }
    }

    /// Removes an upload that never made it.
    ///
    /// Best effort by construction: the caller is already throwing the reason
    /// the upload failed, and a session that has just dropped cannot be asked
    /// to tidy up after itself.
    private func discardTemporary(_ path: String, on sftp: OpaquePointer) {
        guard !isBroken else { return }
        connection.retry {
            path.withCString { libssh2_sftp_unlink_ex(sftp, $0, UInt32(path.utf8.count)) }
        }
    }

    // MARK: - Attributes and errors

    /// The server's own reason, as a typed error.
    ///
    /// `libssh2_sftp_last_error` is only meaningful when the transport-level
    /// error was LIBSSH2_ERROR_SFTP_PROTOCOL — otherwise the connection itself
    /// failed and the last SFTP status is stale. Reporting a dropped link as
    /// whatever status happened to be sitting there is how "the network went
    /// away" ends up displayed as "permission denied".
    private func error(on sftp: OpaquePointer, path: String) -> Error {
        guard let session,
              libssh2_session_last_errno(session) == LIBSSH2_ERROR_SFTP_PROTOCOL else {
            // The transport is gone, so this session is finished. Recording it
            // is what makes the redial in `openLocked` happen at all — see
            // `isBroken`.
            isBroken = true
            return SFTPError.connectionLost(path)
        }
        return SFTPError(status: UInt32(truncatingIfNeeded: libssh2_sftp_last_error(sftp)),
                         path: path)
    }

    /// The size the server reported, or nil when it reported none. Zero is a
    /// real size, so the two must not collapse into one value.
    private static func reportedSize(of attributes: LIBSSH2_SFTP_ATTRIBUTES) -> Int64? {
        guard attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0 else { return nil }
        // bitPattern, not Int64(_:) — filesize is unsigned and the trapping
        // initializer would kill the extension process on any value above
        // Int64.max, whether the server is lying or merely odd.
        return Int64(bitPattern: attributes.filesize)
    }

    /// The permission bits the server reported, or nil when it reported none.
    private static func permissions(of attributes: LIBSSH2_SFTP_ATTRIBUTES) -> Int? {
        guard attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 else { return nil }
        return Int(attributes.permissions & 0o7777)
    }

    /// Absent permissions read as a plain file — see `entry`.
    private static func kind(of attributes: LIBSSH2_SFTP_ATTRIBUTES) -> SFTPEntry.Kind {
        SFTPEntry.Kind(posixMode: UInt32(truncatingIfNeeded: attributes.permissions))
    }

    private func entry(name: String, in directory: String,
                       attributes: LIBSSH2_SFTP_ATTRIBUTES) -> SFTPEntry {
        // A server may omit any attribute. Absent permissions become 0, which
        // SFTPEntry.Kind reads as a plain file — the safe reading, since
        // guessing a directory would have the system enumerate something that
        // cannot be enumerated.
        let hasPermissions = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
        let hasTime = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0

        return SFTPEntry(
            path: RemotePath.join(directory, name),
            size: Self.reportedSize(of: attributes) ?? 0,
            modified: Date(timeIntervalSince1970: hasTime ? TimeInterval(attributes.mtime) : 0),
            // The raw st_mode, type bits included: `SFTPEntry.kind` needs them
            // and `SFTPEntry.permissions` masks them off.
            mode: hasPermissions ? UInt32(truncatingIfNeeded: attributes.permissions) : 0)
    }
}
#endif
