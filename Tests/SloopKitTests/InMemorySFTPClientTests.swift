// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// The double is only worth having if it refuses what a real server refuses.
/// Every test here pins a rule the File Provider layer is written against;
/// a more permissive double would turn a server-side failure into a code path
/// nothing ever exercises.
final class InMemorySFTPClientTests: XCTestCase {
    private func client() -> InMemorySFTPClient {
        let client = InMemorySFTPClient(home: "/home/matt")
        client.addFile("/home/matt/notes.txt", contents: Data("hello".utf8))
        client.addDirectory("/home/matt/docs")
        client.addFile("/home/matt/docs/a.txt", contents: Data("a".utf8))
        return client
    }

    func testListReturnsOnlyDirectChildren() throws {
        let entries = try client().list("/home/matt")
        XCTAssertEqual(entries.map(\.name), ["docs", "notes.txt"])
    }

    func testListingAFileIsNotADirectory() {
        XCTAssertThrowsError(try client().list("/home/matt/notes.txt")) { error in
            XCTAssertEqual(error as? SFTPError, .notADirectory("/home/matt/notes.txt"))
        }
    }

    func testListingSomethingAbsentIsNotFound() {
        XCTAssertThrowsError(try client().list("/nope")) { error in
            XCTAssertEqual(error as? SFTPError, .noSuchFile("/nope"))
        }
    }

    func testStatReportsSizeAndKind() throws {
        let entry = try client().stat("/home/matt/notes.txt")
        XCTAssertEqual(entry.size, 5)
        XCTAssertEqual(entry.kind, .file)
    }

    func testReadAndWriteRoundTripThroughDisk() throws {
        let client = client()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var reported: (Int64, Int64) = (0, 0)
        try client.read("/home/matt/notes.txt", into: scratch) { reported = ($0, $1) }
        XCTAssertEqual(try Data(contentsOf: scratch), Data("hello".utf8))
        XCTAssertEqual(reported.0, 5)
        XCTAssertEqual(reported.1, 5)

        try client.write(scratch, to: "/home/matt/copy.txt") { _, _ in }
        XCTAssertEqual(client.contents(of: "/home/matt/copy.txt"), Data("hello".utf8))
    }

    func testWritingIntoAMissingDirectoryFails() {
        let client = client()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? Data().write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        XCTAssertThrowsError(try client.write(scratch, to: "/nope/x.txt") { _, _ in })
    }

    func testMakeDirectoryRefusesAnExistingPath() {
        XCTAssertThrowsError(try client().makeDirectory("/home/matt/docs")) { error in
            XCTAssertEqual(error as? SFTPError, .alreadyExists("/home/matt/docs"))
        }
    }

    /// The File Provider system deletes item by item. A double that recursed
    /// here would hide the fact that the extension must too.
    func testRemoveRefusesANonEmptyDirectory() {
        XCTAssertThrowsError(try client().remove("/home/matt/docs")) { error in
            XCTAssertEqual(error as? SFTPError, .directoryNotEmpty("/home/matt/docs"))
        }
    }

    func testRemoveAcceptsAnEmptiedDirectory() throws {
        let client = client()
        try client.remove("/home/matt/docs/a.txt")
        try client.remove("/home/matt/docs")
        XCTAssertFalse(client.exists("/home/matt/docs"))
    }

    func testRenameCarriesTheWholeSubtree() throws {
        let client = client()
        try client.rename("/home/matt/docs", to: "/home/matt/archive")
        XCTAssertFalse(client.exists("/home/matt/docs"))
        XCTAssertFalse(client.exists("/home/matt/docs/a.txt"))
        XCTAssertTrue(client.exists("/home/matt/archive"))
        XCTAssertEqual(client.contents(of: "/home/matt/archive/a.txt"), Data("a".utf8))
    }

    /// A sibling whose name merely starts with the renamed directory's name
    /// must not be dragged along.
    func testRenameLeavesPrefixSiblingsAlone() throws {
        let client = client()
        client.addFile("/home/matt/docsignore.txt", contents: Data())
        try client.rename("/home/matt/docs", to: "/home/matt/archive")
        XCTAssertTrue(client.exists("/home/matt/docsignore.txt"))
    }

    func testRenameRefusesToClobber() {
        XCTAssertThrowsError(
            try client().rename("/home/matt/notes.txt", to: "/home/matt/docs")
        ) { error in
            XCTAssertEqual(error as? SFTPError, .alreadyExists("/home/matt/docs"))
        }
    }

    func testDefaultDirectoryIsTheHomeItWasBuiltWith() throws {
        XCTAssertEqual(try client().defaultDirectory(), "/home/matt")
        XCTAssertTrue(client().exists("/home"))
    }
}
