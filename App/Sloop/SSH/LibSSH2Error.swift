// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit
#if canImport(CSSH)
import CSSH

/// libssh2's own description of the most recent failure on a session.
///
/// Shared by `LibSSH2Transport` and `LibSSH2CommandRunner`, which authenticate
/// the same way and previously reported every failure as a bare
/// "authentication failed" — indistinguishable between a rejected key, a wrong
/// password, and a server that never offered the method.
///
/// Deliberately makes no further libssh2 calls: an error path is the worst
/// place to risk another blocking round-trip on a non-blocking session.
func libssh2LastError(_ session: OpaquePointer) -> String {
    var message: UnsafeMutablePointer<CChar>?
    var length: Int32 = 0
    let code = libssh2_session_last_error(session, &message, &length, 0)
    let text = message.map { String(cString: $0) } ?? ""
    return text.isEmpty ? "libssh2 error \(code)" : "\(text) [libssh2 \(code)]"
}
#endif
