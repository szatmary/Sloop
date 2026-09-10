// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if canImport(CSSH)
import CSSH

/// Process-wide libssh2 initialization, done exactly once.
///
/// It used to be per-connection, paired with a `defer { libssh2_exit() }`. That
/// is safe only while one session exists at a time, which stopped being true
/// the moment the terminal grew tabs — closing one tab called `libssh2_exit()`
/// underneath every other live session — and is emphatically untrue now that an
/// SFTP pool keeps sessions open per host. libssh2 does not reference-count
/// these, so the fix is to initialize once and never tear down; the library's
/// own documentation treats `exit` as an end-of-program call.
///
/// Extracted from `LibSSH2Connection` once `KeyValidator` needed the same
/// guarantee without opening a connection. Two copies of a "once" is not a
/// once.
enum LibSSH2Library {
    /// `libssh2_init`'s return code, evaluated on first access and never again.
    private static let initializeOnce: Int32 = libssh2_init(0)

    /// True once the library is usable. Cheap to call repeatedly.
    static var isReady: Bool { initializeOnce == 0 }
}
#endif
