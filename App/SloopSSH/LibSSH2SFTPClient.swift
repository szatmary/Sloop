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
            // Only worth asking politely while the socket is alive. On a dead
            // one `shutdown` cannot complete, and the EAGAIN loop would spin
            // against a socket that will never be writable again.
            while libssh2_sftp_shutdown(sftp) == LIBSSH2_ERROR_EAGAIN { connection.waitSocket() }
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

        let handle = try open(path, on: sftp, flags: 0, mode: 0, kind: LIBSSH2_SFTP_OPENDIR)
        defer { closeHandle(handle) }

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
            // them to the File Provider system would make the replica a cyclic
            // graph, which it will happily follow.
            guard filename != ".", filename != ".." else { continue }
            entries.append(entry(name: filename, in: path, attributes: attributes))
        }
        return entries
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

        // bitPattern, not Int64(_:) — filesize is unsigned and the trapping
        // initializer would kill the extension process on any value above
        // Int64.max, whether the server is lying or merely odd. `entry()`
        // already reads the same field this way.
        let total = Int64(bitPattern: try statLocked(path, on: sftp,
                                                     kind: LIBSSH2_SFTP_STAT).filesize)
        let handle = try open(path, on: sftp, flags: UInt(LIBSSH2_FXF_READ), mode: 0,
                              kind: LIBSSH2_SFTP_OPENFILE)
        defer { closeHandle(handle) }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw SFTPError.permissionDenied(destination.path)
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }

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
            progress(transferred, max(total, transferred))
        }
    }

    func write(_ source: URL, to path: String,
               progress: (Int64, Int64) -> Void) throws {
        let path = RemotePath.normalize(path)
        lock.lock(); defer { lock.unlock() }
        let sftp = try subsystem()

        let total = Int64((try FileManager.default.attributesOfItem(atPath: source.path)[.size]
                           as? NSNumber)?.int64Value ?? 0)
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }

        // 0o644 applies only when the file is being created; an existing file
        // keeps its own permissions.
        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        let handle = try open(path, on: sftp, flags: flags, mode: 0o644,
                              kind: LIBSSH2_SFTP_OPENFILE)
        defer { closeHandle(handle) }

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
                progress(transferred, max(total, transferred))
            }
        }
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
        guard attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 else {
            throw SFTPError.unsupported(path)
        }
        let isDirectory = SFTPEntry.Kind(
            posixMode: UInt32(truncatingIfNeeded: attributes.permissions)) == .directory

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
        // No LIBSSH2_SFTP_RENAME_OVERWRITE: a move that silently replaces the
        // file already at the destination is data loss the user never asked
        // for. EEXIST lets Files.app offer its own "keep both" instead.
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

    private func closeHandle(_ handle: OpaquePointer) {
        while libssh2_sftp_close_handle(handle) == LIBSSH2_ERROR_EAGAIN {
            connection.waitSocket()
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
            return SFTPError.connectionLost(path)
        }
        return SFTPError(status: UInt32(truncatingIfNeeded: libssh2_sftp_last_error(sftp)),
                         path: path)
    }

    private func entry(name: String, in directory: String,
                       attributes: LIBSSH2_SFTP_ATTRIBUTES) -> SFTPEntry {
        // A server may omit any attribute. Absent permissions become 0, which
        // SFTPEntry.Kind reads as a plain file — the safe reading, since
        // guessing a directory would have the system enumerate something that
        // cannot be enumerated.
        let hasPermissions = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
        let hasTime = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
        let hasSize = attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0

        return SFTPEntry(
            path: RemotePath.join(directory, name),
            size: hasSize ? Int64(bitPattern: attributes.filesize) : 0,
            modified: Date(timeIntervalSince1970: hasTime ? TimeInterval(attributes.mtime) : 0),
            mode: hasPermissions ? UInt32(truncatingIfNeeded: attributes.permissions) : 0)
    }
}
#endif
