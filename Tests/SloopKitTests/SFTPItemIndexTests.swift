// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class SFTPItemIndexTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func file(_ path: String, size: Int64 = 1, at seconds: TimeInterval = 0) -> SFTPEntry {
        SFTPEntry(path: path, size: size,
                  modified: Date(timeIntervalSince1970: seconds), mode: 0o100_644)
    }

    private func directory(_ path: String) -> SFTPEntry {
        SFTPEntry(path: path, size: 0,
                  modified: Date(timeIntervalSince1970: 0), mode: 0o040_755)
    }

    // MARK: - Identifiers

    func testTheSamePathAlwaysGetsTheSameIdentifier() {
        let index = SFTPItemIndex(fileURL: scratch)
        let first = index.identifier(for: "/a/b")
        XCTAssertEqual(index.identifier(for: "/a/b"), first)
        XCTAssertNotEqual(index.identifier(for: "/a/c"), first)
    }

    func testDifferentSpellingsOfOnePathShareAnIdentifier() {
        let index = SFTPItemIndex(fileURL: scratch)
        XCTAssertEqual(index.identifier(for: "/a//b/"), index.identifier(for: "/a/b"))
    }

    func testIdentifierResolvesBackToItsPath() {
        let index = SFTPItemIndex(fileURL: scratch)
        let id = index.identifier(for: "/a/b")
        XCTAssertEqual(index.path(for: id), "/a/b")
        XCTAssertNil(index.path(for: UUID()))
    }

    // MARK: - Moves

    /// The whole reason this type exists: a renamed item keeps its identifier,
    /// because NSFileProviderItemIdentifier must survive a rename.
    func testRenameKeepsTheIdentifier() {
        let index = SFTPItemIndex(fileURL: scratch)
        let id = index.identifier(for: "/a/b")
        index.move(from: "/a/b", to: "/a/c")
        XCTAssertEqual(index.path(for: id), "/a/c")
        XCTAssertEqual(index.identifier(for: "/a/c"), id)
    }

    func testRenamingADirectoryCarriesDescendantIdentifiers() {
        let index = SFTPItemIndex(fileURL: scratch)
        let dir = index.identifier(for: "/a/docs")
        let child = index.identifier(for: "/a/docs/x.txt")
        let deep = index.identifier(for: "/a/docs/sub/y.txt")

        index.move(from: "/a/docs", to: "/a/archive")

        XCTAssertEqual(index.path(for: dir), "/a/archive")
        XCTAssertEqual(index.path(for: child), "/a/archive/x.txt")
        XCTAssertEqual(index.path(for: deep), "/a/archive/sub/y.txt")
    }

    func testRenamingADirectoryLeavesPrefixSiblingsAlone() {
        let index = SFTPItemIndex(fileURL: scratch)
        let sibling = index.identifier(for: "/a/docsignore")
        index.move(from: "/a/docs", to: "/a/archive")
        XCTAssertEqual(index.path(for: sibling), "/a/docsignore")
    }

    func testForgettingADirectoryDropsItsSubtree() {
        let index = SFTPItemIndex(fileURL: scratch)
        let dir = index.identifier(for: "/a/docs")
        let child = index.identifier(for: "/a/docs/x.txt")
        index.forget("/a/docs")
        XCTAssertNil(index.path(for: dir))
        XCTAssertNil(index.path(for: child))
    }

    // MARK: - Change detection

    func testFirstListingIsAllAdditions() {
        let index = SFTPItemIndex(fileURL: scratch)
        let changes = index.apply(listing: [file("/a/x"), file("/a/y")], to: "/a")
        XCTAssertEqual(Set(changes.added.map(\.path)), ["/a/x", "/a/y"])
        XCTAssertTrue(changes.updated.isEmpty)
        XCTAssertTrue(changes.removedIdentifiers.isEmpty)
    }

    func testAnUnchangedListingReportsNothing() {
        let index = SFTPItemIndex(fileURL: scratch)
        _ = index.apply(listing: [file("/a/x")], to: "/a")
        let changes = index.apply(listing: [file("/a/x")], to: "/a")
        XCTAssertTrue(changes.isEmpty)
    }

    func testAGrownFileIsAnUpdateNotAnAddition() {
        let index = SFTPItemIndex(fileURL: scratch)
        _ = index.apply(listing: [file("/a/x", size: 1)], to: "/a")
        let changes = index.apply(listing: [file("/a/x", size: 99)], to: "/a")
        XCTAssertEqual(changes.updated.map(\.path), ["/a/x"])
        XCTAssertTrue(changes.added.isEmpty)
    }

    /// A file rewritten in place keeps its size and changes only its mtime —
    /// the common case for an edited config, and invisible to a size-only diff.
    func testATouchedFileOfTheSameSizeIsStillAnUpdate() {
        let index = SFTPItemIndex(fileURL: scratch)
        _ = index.apply(listing: [file("/a/x", size: 10, at: 0)], to: "/a")
        let changes = index.apply(listing: [file("/a/x", size: 10, at: 500)], to: "/a")
        XCTAssertEqual(changes.updated.map(\.path), ["/a/x"])
    }

    func testAChmodIsAnUpdate() {
        let index = SFTPItemIndex(fileURL: scratch)
        _ = index.apply(listing: [file("/a/x")], to: "/a")
        let readOnly = SFTPEntry(path: "/a/x", size: 1,
                                 modified: Date(timeIntervalSince1970: 0), mode: 0o100_444)
        XCTAssertEqual(index.apply(listing: [readOnly], to: "/a").updated.map(\.path), ["/a/x"])
    }

    func testADisappearedFileIsReportedByItsOldIdentifier() {
        let index = SFTPItemIndex(fileURL: scratch)
        _ = index.apply(listing: [file("/a/x"), file("/a/y")], to: "/a")
        let goneID = index.identifier(for: "/a/y")
        let changes = index.apply(listing: [file("/a/x")], to: "/a")
        XCTAssertEqual(changes.removedIdentifiers, [goneID])
        XCTAssertNil(index.path(for: goneID))
    }

    /// The system cannot change an item's type in place. A path that was a file
    /// and is now a directory is a different item and must be reported as a
    /// removal plus an addition, under a fresh identifier.
    func testAPathThatChangesTypeGetsANewIdentity() {
        let index = SFTPItemIndex(fileURL: scratch)
        _ = index.apply(listing: [file("/a/x")], to: "/a")
        let oldID = index.identifier(for: "/a/x")

        let changes = index.apply(listing: [directory("/a/x")], to: "/a")

        XCTAssertEqual(changes.removedIdentifiers, [oldID])
        XCTAssertEqual(changes.added.map(\.path), ["/a/x"])
        XCTAssertNotEqual(index.identifier(for: "/a/x"), oldID)
    }

    func testChangesInOneDirectoryDoNotDisturbAnother() {
        let index = SFTPItemIndex(fileURL: scratch)
        _ = index.apply(listing: [file("/a/x")], to: "/a")
        _ = index.apply(listing: [file("/b/y")], to: "/b")
        let changes = index.apply(listing: [], to: "/b")
        XCTAssertEqual(changes.removedIdentifiers.count, 1)
        XCTAssertEqual(try? index.snapshotPaths(of: "/a"), ["/a/x"])
    }

    // MARK: - Anchors

    func testTheAnchorAdvancesOnlyWhenSomethingChanged() {
        let index = SFTPItemIndex(fileURL: scratch)
        let start = index.anchor
        _ = index.apply(listing: [file("/a/x")], to: "/a")
        let afterAdd = index.anchor
        XCTAssertGreaterThan(afterAdd, start)

        _ = index.apply(listing: [file("/a/x")], to: "/a")
        XCTAssertEqual(index.anchor, afterAdd, "an unchanged listing must not invalidate the system's anchor")
    }

    func testMovesAndForgetsAdvanceTheAnchorToo() {
        let index = SFTPItemIndex(fileURL: scratch)
        _ = index.identifier(for: "/a/x")
        let before = index.anchor
        index.move(from: "/a/x", to: "/a/y")
        XCTAssertGreaterThan(index.anchor, before)
        let afterMove = index.anchor
        index.forget("/a/y")
        XCTAssertGreaterThan(index.anchor, afterMove)
    }

    // MARK: - Persistence

    func testIdentifiersAndSnapshotsSurviveAReload() throws {
        let index = SFTPItemIndex(fileURL: scratch)
        let id = index.identifier(for: "/a/x")
        _ = index.apply(listing: [file("/a/x")], to: "/a")
        let anchor = index.anchor
        try index.save()

        let reloaded = SFTPItemIndex(fileURL: scratch)
        XCTAssertEqual(reloaded.identifier(for: "/a/x"), id)
        XCTAssertEqual(reloaded.anchor, anchor)
        XCTAssertTrue(reloaded.apply(listing: [file("/a/x")], to: "/a").isEmpty,
                      "a reloaded snapshot must not re-report every item as new")
    }

    /// A corrupt index is recoverable — identifiers are re-minted and the
    /// system re-imports. Refusing to start would strand the domain instead.
    func testACorruptIndexStartsEmptyRatherThanRefusingToLoad() throws {
        try Data("not json".utf8).write(to: scratch)
        let index = SFTPItemIndex(fileURL: scratch)
        XCTAssertNotNil(index.identifier(for: "/a"))
    }
}
