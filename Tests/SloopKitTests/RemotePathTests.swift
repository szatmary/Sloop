// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class RemotePathTests: XCTestCase {
    func testNormalizeAddsLeadingSlashAndCollapsesSeparators() {
        XCTAssertEqual(RemotePath.normalize("a//b"), "/a/b")
        XCTAssertEqual(RemotePath.normalize("/a///b/"), "/a/b")
        XCTAssertEqual(RemotePath.normalize(""), "/")
        XCTAssertEqual(RemotePath.normalize("/"), "/")
    }

    func testNormalizeResolvesDotSegments() {
        XCTAssertEqual(RemotePath.normalize("/a/./b"), "/a/b")
        XCTAssertEqual(RemotePath.normalize("/a/b/.."), "/a")
        XCTAssertEqual(RemotePath.normalize("/a/b/../../c"), "/c")
    }

    /// A `..` that would climb past root stops at root rather than escaping it
    /// or producing a path the server would read differently than we do.
    func testNormalizeCannotEscapeRoot() {
        XCTAssertEqual(RemotePath.normalize("/../.."), "/")
        XCTAssertEqual(RemotePath.normalize("/a/../../b"), "/b")
    }

    func testJoinAndParentAndName() {
        XCTAssertEqual(RemotePath.join("/a", "b"), "/a/b")
        XCTAssertEqual(RemotePath.join("/", "b"), "/b")
        XCTAssertEqual(RemotePath.parent("/a/b/c"), "/a/b")
        XCTAssertEqual(RemotePath.parent("/a"), "/")
        XCTAssertEqual(RemotePath.parent("/"), "/")
        XCTAssertEqual(RemotePath.name("/a/b/c"), "c")
        XCTAssertEqual(RemotePath.name("/"), "/")
    }

    /// Descendant checks drive directory renames, where a prefix match on the
    /// raw string would wrongly claim "/a/bc" as a child of "/a/b".
    func testIsDescendantRequiresASegmentBoundary() {
        XCTAssertTrue(RemotePath.isDescendant("/a/b/c", of: "/a/b"))
        XCTAssertFalse(RemotePath.isDescendant("/a/bc", of: "/a/b"))
        XCTAssertFalse(RemotePath.isDescendant("/a/b", of: "/a/b"))
        XCTAssertTrue(RemotePath.isDescendant("/a", of: "/"))
    }

    func testReparentRewritesOnlyThePrefix() {
        XCTAssertEqual(RemotePath.reparent("/a/b/c", from: "/a/b", to: "/x/y"), "/x/y/c")
        XCTAssertEqual(RemotePath.reparent("/a/b", from: "/a/b", to: "/x/y"), "/x/y")
        XCTAssertNil(RemotePath.reparent("/a/bc", from: "/a/b", to: "/x/y"))
    }
}
