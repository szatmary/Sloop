// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// One entry in a remote directory: what a `readdir` or `stat` told us.
///
/// Deliberately not a `URLResourceValues`-shaped bag of optionals. Every field
/// here is one the File Provider layer must supply for *every* item, so an
/// absent value has to be decided once, at the point the attributes are read
/// from the server, rather than defaulted differently by each consumer.
public struct SFTPEntry: Hashable, Sendable {
    /// What Files.app can represent. Anything else — a socket, a fifo, a device
    /// node — is `.other` and is listed but not openable, which is honest;
    /// hiding it would make a directory look empty that isn't.
    public enum Kind: Hashable, Sendable {
        case file
        case directory
        case symlink
        case other

        /// The file-type bits of a POSIX `st_mode`, which SFTP carries in the
        /// `permissions` attribute.
        ///
        /// Absent type bits mean `.file`. A server that sends permissions
        /// without a type is not describing a directory, and guessing one is
        /// how a replica acquires a container that enumerates forever.
        public init(posixMode: UInt32) {
            switch posixMode & 0o170_000 {
            case 0o040_000: self = .directory
            case 0o120_000: self = .symlink
            case 0o100_000, 0: self = .file
            default: self = .other
            }
        }
    }

    /// Absolute and canonical — see `RemotePath.normalize`.
    public let path: String
    public let size: Int64
    public let modified: Date
    /// The raw `st_mode`, type bits included. `permissions` masks them off.
    public let mode: UInt32

    public init(path: String, size: Int64, modified: Date, mode: UInt32) {
        self.path = RemotePath.normalize(path)
        self.size = size
        self.modified = modified
        self.mode = mode
    }

    public var name: String { RemotePath.name(path) }
    public var kind: Kind { Kind(posixMode: mode) }
    public var isDirectory: Bool { kind == .directory }
    /// Just the permission bits — what a chmod would take.
    public var permissions: UInt32 { mode & 0o7777 }

    /// Identifies these *contents*, for deciding whether the server's copy has
    /// moved on since a caller last looked.
    ///
    /// Size and mtime, because that is all SFTP offers — no etag, no checksum.
    /// Deliberately not the mode: a `chmod` must not read as a content change,
    /// or the system re-downloads a file whose bytes never moved and every
    /// save after one is refused as a conflict.
    ///
    /// Lives here rather than in the File Provider layer because two callers
    /// need the same answer — the item version the system stores, and the
    /// comparison `replaceFile` makes against it. Two spellings of one formula
    /// would drift into a conflict that fires on everything or nothing.
    public var contentVersion: Data {
        Data("\(size)-\(modified.timeIntervalSince1970)".utf8)
    }
}

/// Why an SFTP operation failed, kept as a type all the way to the boundary
/// that has to act on it.
///
/// The alternative — one case carrying a string — is the mistake `ConnectionState`
/// already makes and that `Docs/ROADMAP.md` still carries as an open item:
/// stringify at the boundary and nothing downstream can tell a missing file
/// from a refused permission from a dropped link. Here the distinction is not
/// cosmetic: the File Provider extension turns each case into a *different*
/// instruction to the system — drop the item, offer to resolve a name
/// collision, restore the directory it just deleted, or retry — and a single
/// string could only ever produce one of them.
///
/// The translation happens in `FileProviderError`, not here, and it does not go
/// through errno. An earlier version of this comment claimed Files.app reads
/// POSIX codes directly; it does not. `NSFileProviderReplicatedExtension`
/// accepts `NSFileProviderErrorDomain` and `NSCocoaErrorDomain` and treats
/// every other domain — POSIX included — as a transient failure to be retried,
/// so mapping to errno at that boundary meant a deleted file was never dropped
/// and a permissions refusal never surfaced.
public enum SFTPError: Error, LocalizedError, Hashable, Sendable {
    case noSuchFile(String)
    case permissionDenied(String)
    case notADirectory(String)
    case isADirectory(String)
    case directoryNotEmpty(String)
    case alreadyExists(String)
    case noSpace(String)
    case quotaExceeded(String)
    case connectionLost(String)
    /// The server's copy of this file changed since the caller last read it,
    /// so writing would discard somebody else's edit.
    case contentChanged(String)
    /// Fewer bytes moved than the file holds.
    ///
    /// The one failure that can otherwise pass for success: the bytes that did
    /// arrive are a perfectly valid file, only a shorter one, and nothing in an
    /// SFTP data stream carries a length to contradict it. No server sends this
    /// — a client detects it by counting — so it has no `SSH_FX_*` status, and
    /// the counts travel with it because "stopped at 4 KiB of 900 MiB" is the
    /// only actionable thing left to say afterwards.
    case truncated(String, expected: Int64, actual: Int64)
    /// A file the caller asked to read entirely into memory is bigger than the
    /// ceiling it named. Only `readData` raises this — the streaming `read`
    /// has no size it cannot handle.
    case tooLarge(String, limit: Int)
    case unsupported(String)
    /// A status this build has no specific meaning for. The raw code is kept
    /// rather than flattened away: it is the only evidence left when a server
    /// does something unexpected, and a bug report that says "code 4" is
    /// actionable where "the operation failed" is not.
    case protocolFailure(String, code: UInt32)

    /// Maps an `SSH_FX_*` status, as libssh2 reports it via
    /// `libssh2_sftp_last_error`.
    public init(status: UInt32, path: String) {
        switch status {
        case 2, 10: self = .noSuchFile(path)          // NO_SUCH_FILE, NO_SUCH_PATH
        case 3, 12: self = .permissionDenied(path)    // PERMISSION_DENIED, WRITE_PROTECT
        case 7:     self = .connectionLost(path)
        case 8:     self = .unsupported(path)
        case 11:    self = .alreadyExists(path)
        case 14:    self = .noSpace(path)
        case 15:    self = .quotaExceeded(path)
        case 18:    self = .directoryNotEmpty(path)
        case 19:    self = .notADirectory(path)
        default:    self = .protocolFailure(path, code: status)
        }
    }

    /// The errno this failure corresponds to.
    ///
    /// *Not* what the File Provider extension reports — see the note on the
    /// type. This is the plain POSIX reading of each case, for callers that
    /// want one (a CLI, a future in-app browser, a test asserting the meaning
    /// of a status code). The File Provider boundary maps to
    /// `NSFileProviderErrorDomain`/`NSCocoaErrorDomain` instead.
    public var posixCode: Int32 {
        switch self {
        case .noSuchFile:        return ENOENT
        case .permissionDenied:  return EACCES
        case .notADirectory:     return ENOTDIR
        case .isADirectory:      return EISDIR
        case .directoryNotEmpty: return ENOTEMPTY
        case .alreadyExists:     return EEXIST
        // The closest POSIX has. No syscall reports "somebody else edited
        // this"; the check is ours, made before the write rather than by the
        // server during it.
        case .contentChanged:    return EEXIST
        case .noSpace:           return ENOSPC
        case .quotaExceeded:     return EDQUOT
        case .connectionLost:    return ECONNRESET
        case .truncated:         return EIO
        case .tooLarge:          return EFBIG
        case .unsupported:       return ENOTSUP
        case .protocolFailure:   return EIO
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noSuchFile(let path):        return "\(path) doesn't exist on the server"
        case .permissionDenied(let path):  return "the server refused access to \(path)"
        case .notADirectory(let path):     return "\(path) isn't a directory"
        case .isADirectory(let path):      return "\(path) is a directory"
        case .directoryNotEmpty(let path): return "\(path) isn't empty"
        case .alreadyExists(let path):     return "\(path) already exists"
        case .noSpace(let path):           return "the server is out of space writing \(path)"
        case .quotaExceeded(let path):     return "writing \(path) would exceed your quota"
        case .connectionLost(let path):    return "the connection dropped during \(path)"
        case .contentChanged(let path):
            return "\(path) changed on the server since it was last read"
        case .truncated(let path, let expected, let actual):
            return "\(path) transferred \(actual) of \(expected) bytes"
        case .tooLarge(let path, let limit):
            return "\(path) is larger than \(limit) bytes, which is more than this can hold in memory"
        case .unsupported(let path):       return "the server doesn't support that operation on \(path)"
        case .protocolFailure(let path, let code):
            return "the server failed on \(path) with SFTP status \(code)"
        }
    }
}
