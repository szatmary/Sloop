// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class SFTPEntryTests: XCTestCase {
    func testKindComesFromTheFileTypeBitsNotThePermissionBits() {
        XCTAssertEqual(SFTPEntry.Kind(posixMode: 0o100_644), .file)
        XCTAssertEqual(SFTPEntry.Kind(posixMode: 0o040_755), .directory)
        XCTAssertEqual(SFTPEntry.Kind(posixMode: 0o120_777), .symlink)
        // A socket, fifo, or device node is none of the three Files.app knows.
        XCTAssertEqual(SFTPEntry.Kind(posixMode: 0o140_755), .other)
    }

    /// A server that sends no type bits at all (permissions-only attributes)
    /// must not be guessed into a directory — enumerating a regular file as a
    /// container is how a replica fills with phantom children.
    func testKindWithNoTypeBitsIsAFile() {
        XCTAssertEqual(SFTPEntry.Kind(posixMode: 0o644), .file)
    }

    func testNameIsTheFinalPathSegment() {
        let entry = SFTPEntry(path: "/home/matt/notes.txt", size: 12,
                              modified: Date(timeIntervalSince1970: 0),
                              mode: 0o100_644)
        XCTAssertEqual(entry.name, "notes.txt")
        XCTAssertEqual(entry.kind, .file)
    }

    func testPathIsNormalizedOnConstruction() {
        let entry = SFTPEntry(path: "/home//matt/./docs/", size: 0,
                              modified: Date(timeIntervalSince1970: 0),
                              mode: 0o040_755)
        XCTAssertEqual(entry.path, "/home/matt/docs")
        XCTAssertEqual(entry.kind, .directory)
    }

    func testPermissionsMaskOffTheTypeBits() {
        let entry = SFTPEntry(path: "/a", size: 0, modified: Date(), mode: 0o100_600)
        XCTAssertEqual(entry.permissions, 0o600)
    }
}

final class SFTPErrorTests: XCTestCase {
    func testStatusCodesMapToDistinctCases() {
        XCTAssertEqual(SFTPError(status: 2, path: "/a"), .noSuchFile("/a"))
        XCTAssertEqual(SFTPError(status: 3, path: "/a"), .permissionDenied("/a"))
        XCTAssertEqual(SFTPError(status: 7, path: "/a"), .connectionLost("/a"))
        XCTAssertEqual(SFTPError(status: 8, path: "/a"), .unsupported("/a"))
        XCTAssertEqual(SFTPError(status: 11, path: "/a"), .alreadyExists("/a"))
        XCTAssertEqual(SFTPError(status: 14, path: "/a"), .noSpace("/a"))
        XCTAssertEqual(SFTPError(status: 18, path: "/a"), .directoryNotEmpty("/a"))
        XCTAssertEqual(SFTPError(status: 19, path: "/a"), .notADirectory("/a"))
    }

    /// SSH_FX_NO_SUCH_PATH is a different code from SSH_FX_NO_SUCH_FILE and
    /// means the same thing to a caller. Leaving it in the catch-all would have
    /// Files.app show "the operation failed" where it should show "not found".
    func testNoSuchPathIsNotFoundToo() {
        XCTAssertEqual(SFTPError(status: 10, path: "/a"), .noSuchFile("/a"))
    }

    func testUnrecognizedStatusKeepsItsCodeRatherThanBeingFlattened() {
        XCTAssertEqual(SFTPError(status: 4, path: "/a"), .protocolFailure("/a", code: 4))
        XCTAssertEqual(SFTPError(status: 99, path: "/a"), .protocolFailure("/a", code: 99))
    }

    func testEveryCaseCarriesAnErrnoTheSystemUnderstands() {
        XCTAssertEqual(SFTPError.noSuchFile("/a").posixCode, ENOENT)
        XCTAssertEqual(SFTPError.permissionDenied("/a").posixCode, EACCES)
        XCTAssertEqual(SFTPError.notADirectory("/a").posixCode, ENOTDIR)
        XCTAssertEqual(SFTPError.isADirectory("/a").posixCode, EISDIR)
        XCTAssertEqual(SFTPError.directoryNotEmpty("/a").posixCode, ENOTEMPTY)
        XCTAssertEqual(SFTPError.alreadyExists("/a").posixCode, EEXIST)
        XCTAssertEqual(SFTPError.noSpace("/a").posixCode, ENOSPC)
        XCTAssertEqual(SFTPError.quotaExceeded("/a").posixCode, EDQUOT)
        XCTAssertEqual(SFTPError.connectionLost("/a").posixCode, ECONNRESET)
        XCTAssertEqual(SFTPError.truncated("/a", expected: 2, actual: 1).posixCode, EIO)
        XCTAssertEqual(SFTPError.unsupported("/a").posixCode, ENOTSUP)
        XCTAssertEqual(SFTPError.protocolFailure("/a", code: 4).posixCode, EIO)
    }

    func testDescriptionNamesThePathSoTheReasonIsActionable() {
        let message = SFTPError.permissionDenied("/etc/shadow").localizedDescription
        XCTAssertTrue(message.contains("/etc/shadow"), message)
    }

    /// No server sends a "you got a short file" status — a client works it out
    /// by counting — so the counts are the only evidence a bug report can
    /// carry, and dropping them would leave "the transfer failed".
    func testTruncationCarriesTheCountsThatProveIt() {
        let message = SFTPError.truncated("/home/matt/big.iso", expected: 900, actual: 4)
            .localizedDescription
        XCTAssertTrue(message.contains("/home/matt/big.iso"), message)
        XCTAssertTrue(message.contains("900"), message)
        XCTAssertTrue(message.contains("4"), message)
    }
}
