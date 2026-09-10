// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// The two writes that could destroy a file on the server.
///
/// `write` replaces whatever is at the path — it stats the target, keeps its
/// mode, and renames over it. That is right for the one caller that means to
/// replace, and wrong for the two that do not: creating a *new* file, and
/// saving an edit made against a copy the server has since moved on from.
/// Both guards live here rather than in the extension so they can be exercised
/// against `InMemorySFTPClient`, which is what the protocol's own doc comment
/// has always claimed happens.
final class SFTPGuardedWriteTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func file(_ text: String) throws -> URL {
        let url = scratch.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Creating must not replace

    /// The finding: a `report.txt` written over SSH since the last listing was
    /// destroyed when the user saved a new one from another app.
    func testCreateRefusesToReplaceAnExistingFile() throws {
        let client = InMemorySFTPClient()
        client.addFile("/home/matt/report.txt", contents: Data("written on the server".utf8))

        XCTAssertThrowsError(
            try client.createFile(try file("from the phone"),
                                  at: "/home/matt/report.txt",
                                  mayAlreadyExist: false)
        ) { error in
            guard case SFTPError.alreadyExists = error else {
                return XCTFail("expected .alreadyExists, got \(error)")
            }
        }

        XCTAssertEqual(client.contents(of: "/home/matt/report.txt"),
                       Data("written on the server".utf8),
                       "the server's copy must be untouched")
    }

    func testCreateWritesWhenNothingIsThere() throws {
        let client = InMemorySFTPClient()
        let entry = try client.createFile(try file("new"),
                                          at: "/home/matt/new.txt",
                                          mayAlreadyExist: false)
        XCTAssertEqual(entry.path, "/home/matt/new.txt")
        XCTAssertEqual(client.contents(of: "/home/matt/new.txt"), Data("new".utf8))
    }

    /// `mayAlreadyExist` means the system is retrying a create of ours that may
    /// have partly landed. Writing again is what repairs a truncated first
    /// attempt; returning the existing item would leave it truncated.
    func testCreateOverwritesWhenItIsRetryingItsOwnAttempt() throws {
        let client = InMemorySFTPClient()
        client.addFile("/home/matt/half.txt", contents: Data("half".utf8))

        let entry = try client.createFile(try file("whole"),
                                          at: "/home/matt/half.txt",
                                          mayAlreadyExist: true)

        XCTAssertEqual(entry.path, "/home/matt/half.txt")
        XCTAssertEqual(client.contents(of: "/home/matt/half.txt"), Data("whole".utf8))
    }

    /// A symlink occupies the name. Checking with `stat` would follow it and
    /// find nothing when it dangles, then write straight through it.
    func testCreateRefusesToReplaceASymlinkEvenABrokenOne() throws {
        let client = InMemorySFTPClient()
        client.addSymlink("/home/matt/link.txt", to: "/home/matt/gone")

        XCTAssertThrowsError(
            try client.createFile(try file("x"), at: "/home/matt/link.txt",
                                  mayAlreadyExist: false))
    }

    // MARK: - Saving must not clobber a newer copy

    /// Edit on the phone offline, edit in vim on the server, phone comes back:
    /// the server's edit was gone. The contract puts conflict detection here.
    func testReplaceRefusesWhenTheServerCopyMovedOn() throws {
        let client = InMemorySFTPClient()
        client.addFile("/home/matt/notes.md", contents: Data("v1".utf8))
        let seen = try client.stat("/home/matt/notes.md").contentVersion

        // Somebody edits it on the server.
        client.addFile("/home/matt/notes.md", contents: Data("v2 from vim".utf8),
                       modified: Date(timeIntervalSince1970: 5000))

        XCTAssertThrowsError(
            try client.replaceFile(try file("v1 plus my edit"),
                                   at: "/home/matt/notes.md",
                                   ifContentVersionMatches: seen)
        ) { error in
            guard case SFTPError.contentChanged = error else {
                return XCTFail("expected .contentChanged, got \(error)")
            }
        }

        XCTAssertEqual(client.contents(of: "/home/matt/notes.md"),
                       Data("v2 from vim".utf8),
                       "the server's newer copy must survive")
    }

    func testReplaceProceedsWhenTheServerCopyIsTheOneTheCallerSaw() throws {
        let client = InMemorySFTPClient()
        client.addFile("/home/matt/notes.md", contents: Data("v1".utf8))
        let seen = try client.stat("/home/matt/notes.md").contentVersion

        _ = try client.replaceFile(try file("v2"),
                                   at: "/home/matt/notes.md",
                                   ifContentVersionMatches: seen)

        XCTAssertEqual(client.contents(of: "/home/matt/notes.md"), Data("v2".utf8))
    }

    /// No base version means the caller has nothing to compare, and refusing
    /// every such save would make the location read-only.
    func testReplaceProceedsWhenThereIsNoBaseVersion() throws {
        let client = InMemorySFTPClient()
        client.addFile("/home/matt/notes.md", contents: Data("v1".utf8))

        _ = try client.replaceFile(try file("v2"), at: "/home/matt/notes.md",
                                   ifContentVersionMatches: nil)

        XCTAssertEqual(client.contents(of: "/home/matt/notes.md"), Data("v2".utf8))
    }

    /// Content version tracks the bytes, not the permissions: a chmod must not
    /// read as a conflict, or every save after one would be refused.
    func testAChmodAloneDoesNotCountAsAContentChange() throws {
        let client = InMemorySFTPClient()
        client.addFile("/home/matt/notes.md", contents: Data("v1".utf8), mode: 0o100_644)
        let seen = try client.stat("/home/matt/notes.md").contentVersion

        client.addFile("/home/matt/notes.md", contents: Data("v1".utf8), mode: 0o100_600)

        XCTAssertEqual(try client.stat("/home/matt/notes.md").contentVersion, seen)
    }
}
