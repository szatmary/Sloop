// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Keeping a broken connection from killing the process.
//
// Writing to a socket whose peer has gone away raises SIGPIPE, and SIGPIPE's
// default disposition is to terminate. For an SSH client that is not a corner
// case: a server reboot, a NAT timeout or a path change leaves an RST on the
// connection, and the next keystroke — or `libssh2_session_disconnect_ex` on
// the way out — is the write that finds it. The app disappears with no log
// line and nothing to report.
//
// Darwin has no `MSG_NOSIGNAL`, so the per-write fix available on Linux does
// not exist here, and libssh2 does not set `SO_NOSIGPIPE` itself. Both of the
// layers below are therefore ours to set.

/// Marks one socket so that writing to a dead peer returns `EPIPE` instead of
/// raising SIGPIPE. Call between `socket()` and the first write.
///
/// Throws rather than warning: a socket that cannot be protected is one
/// dropped connection away from taking the app down, so there is no useful
/// degraded mode. The fd stays open and owned by the caller on every path —
/// callers hold more of them than this function can see.
///
/// A no-op off Darwin, where `MSG_NOSIGNAL` at the send site is the answer
/// instead. It still `throws` there so call sites read the same on both.
public func ignoreSIGPIPE(on fd: Int32) throws {
    #if canImport(Darwin)
    var one: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                     &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw SSHError.connectionFailed("setsockopt(SO_NOSIGPIPE) failed: errno \(errno)")
    }
    #endif
}

/// Ignores SIGPIPE for the whole process. Call once, as early as possible, in
/// each executable — the app and the File Provider extension are separate
/// processes and each needs its own call.
///
/// `ignoreSIGPIPE(on:)` covers the sockets Sloop opens itself. This covers the
/// ones it does not: fds produced by tsnet's Go runtime, by URLSession, or by
/// any dependency that opens its own. Redundant with the per-socket option
/// wherever both apply, which is the point — the failure mode is the entire
/// process going away, so it is worth being covered twice.
public func ignoreSIGPIPEProcessWide() {
    signal(SIGPIPE, SIG_IGN)
}
