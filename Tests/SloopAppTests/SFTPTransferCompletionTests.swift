// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// Guarded exactly as its subject is. `LibSSH2SFTPClient` lives inside
// `#if canImport(CSSH)`, and the base `project.yml` — the spec CI generates
// before running these tests — links no libssh2, so without this the whole
// SloopAppTests bundle failed to compile there and *every* app-level test
// stopped running. A test may only assume what the build it runs in contains.
#if canImport(CSSH)
import XCTest
import SloopKit
@testable import SloopSSH

/// The rule that decides whether a finished transfer actually finished.
///
/// Here rather than in SloopKitTests because it belongs to the libssh2 client,
/// and testable at all — unlike the rest of that client — because it needs
/// neither a socket nor a server. Everything else about a dropped link, a
/// refused close, or a redial can only be observed against a real SFTP server.
final class SFTPTransferCompletionTests: XCTestCase {
    /// The failure this whole check exists for: the short file is valid, so
    /// without it an upload that stopped early reports success and the user
    /// keeps a truncated copy.
    func testAShortTransferIsAnError() {
        XCTAssertThrowsError(
            try LibSSH2SFTPClient.verifyComplete(path: "/home/matt/big.iso",
                                                 expected: 900, transferred: 4)
        ) { error in
            XCTAssertEqual(error as? SFTPError,
                           .truncated("/home/matt/big.iso", expected: 900, actual: 4))
        }
    }

    func testAnExactTransferPasses() throws {
        try LibSSH2SFTPClient.verifyComplete(path: "/a", expected: 900, transferred: 900)
    }

    /// Zero is a real length, not "no answer": an empty file transfers no bytes
    /// and is complete.
    func testAnEmptyFileIsComplete() throws {
        try LibSSH2SFTPClient.verifyComplete(path: "/a", expected: 0, transferred: 0)
    }

    /// A log that grew between the stat and the last chunk is not a failure —
    /// everything that was asked for arrived.
    func testATransferLongerThanExpectedPasses() throws {
        try LibSSH2SFTPClient.verifyComplete(path: "/a", expected: 900, transferred: 901)
    }

    /// A server may omit the size attribute entirely. There is then nothing to
    /// compare against, and reading the absence as zero would fail every
    /// download from such a server.
    func testAnUnreportedSizeIsNotCheckedAgainst() throws {
        try LibSSH2SFTPClient.verifyComplete(path: "/a", expected: nil, transferred: 0)
    }
}

#endif  // canImport(CSSH)
