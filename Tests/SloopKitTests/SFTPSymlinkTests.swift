// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// Symlinks, and the one place following them destroys data.
///
/// SFTP has no recursive delete, so `removeRecursively` walks the tree itself.
/// It asked `stat`, which follows links, so a symlink to a directory reported
/// `isDirectory` and the walk went *through* it — unlinking the contents of a
/// directory the system never asked to touch. Reachable from Files.app by
/// renaming a symlinked directory and then deleting it.
final class SFTPSymlinkTests: XCTestCase {

    /// The finding. Deleting a folder that contains a link to somewhere else
    /// must not empty out somewhere else.
    func testRecursiveDeleteDoesNotFollowASymlinkIntoItsTarget() throws {
        let client = InMemorySFTPClient()
        client.addFile("/home/matt/precious/keep.txt", contents: Data("keep".utf8))
        client.addDirectory("/home/matt/doomed")
        client.addSymlink("/home/matt/doomed/link", to: "/home/matt/precious")

        try client.removeRecursively("/home/matt/doomed")

        XCTAssertTrue(client.exists("/home/matt/precious"),
                      "the link's target must survive")
        XCTAssertTrue(client.exists("/home/matt/precious/keep.txt"),
                      "and so must everything inside it")
        XCTAssertFalse(client.exists("/home/matt/doomed"))
        XCTAssertFalse(client.exists("/home/matt/doomed/link"))
    }

    /// The behaviour it must not lose while fixing that: a real subtree still
    /// goes, depth first.
    func testRecursiveDeleteStillRemovesARealSubtree() throws {
        let client = InMemorySFTPClient()
        client.addFile("/home/matt/build/a/one.o")
        client.addFile("/home/matt/build/b/two.o")

        try client.removeRecursively("/home/matt/build")

        XCTAssertFalse(client.exists("/home/matt/build"))
        XCTAssertFalse(client.exists("/home/matt/build/a/one.o"))
    }

    /// Removing the link itself removes the link, never the target.
    func testRemovingASymlinkLeavesItsTargetAlone() throws {
        let client = InMemorySFTPClient()
        client.addFile("/home/matt/real.txt", contents: Data("hi".utf8))
        client.addSymlink("/home/matt/alias", to: "/home/matt/real.txt")

        try client.remove("/home/matt/alias")

        XCTAssertFalse(client.exists("/home/matt/alias"))
        XCTAssertTrue(client.exists("/home/matt/real.txt"))
    }

    /// The two calls differ in exactly one way, and the whole fix rests on it.
    func testStatFollowsALinkAndLstatDoesNot() throws {
        let client = InMemorySFTPClient()
        client.addDirectory("/home/matt/target")
        client.addSymlink("/home/matt/link", to: "/home/matt/target")

        XCTAssertEqual(try client.stat("/home/matt/link").kind, .directory)
        XCTAssertEqual(try client.lstat("/home/matt/link").kind, .symlink)
    }

    /// A link pointing at nothing fails when followed and is still describable
    /// when it is not — which is what lets a broken link be deleted.
    func testABrokenLinkCanStillBeLstattedAndRemoved() throws {
        let client = InMemorySFTPClient()
        client.addSymlink("/home/matt/dangling", to: "/home/matt/gone")

        XCTAssertThrowsError(try client.stat("/home/matt/dangling"))
        XCTAssertEqual(try client.lstat("/home/matt/dangling").kind, .symlink)

        try client.remove("/home/matt/dangling")
        XCTAssertFalse(client.exists("/home/matt/dangling"))
    }

    /// A folder holding a dangling link must not become undeletable.
    func testRecursiveDeleteHandlesADanglingLink() throws {
        let client = InMemorySFTPClient()
        client.addDirectory("/home/matt/doomed")
        client.addSymlink("/home/matt/doomed/dangling", to: "/nowhere")

        try client.removeRecursively("/home/matt/doomed")

        XCTAssertFalse(client.exists("/home/matt/doomed"))
    }

    /// A cycle must not hang the walk.
    func testALinkCycleIsRefusedRatherThanFollowedForever() {
        let client = InMemorySFTPClient()
        client.addSymlink("/home/matt/a", to: "/home/matt/b")
        client.addSymlink("/home/matt/b", to: "/home/matt/a")

        XCTAssertThrowsError(try client.stat("/home/matt/a"))
    }
}
