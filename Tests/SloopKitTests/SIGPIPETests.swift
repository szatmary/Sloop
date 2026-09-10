// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin)
final class SIGPIPETests: XCTestCase {

    /// The process-wide install is the backstop for fds Sloop never opened —
    /// tsnet's, URLSession's — where there is no socket of ours to set an
    /// option on.
    ///
    /// Forced back to `SIG_DFL` first: the test harness may already ignore
    /// SIGPIPE, and asserting against that would pass whether or not the
    /// function does anything at all.
    func testProcessWideInstallChangesTheDispositionFromDefault() {
        let original = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, original) }

        ignoreSIGPIPEProcessWide()

        // `signal` reports the disposition it replaced, so this reads back
        // whatever the call above installed.
        let installed = signal(SIGPIPE, SIG_IGN)
        XCTAssertEqual(unsafeBitCast(installed, to: UnsafeRawPointer?.self),
                       unsafeBitCast(SIG_IGN, to: UnsafeRawPointer?.self),
                       "SIGPIPE must be ignored after the process-wide install")
    }
}
#endif
