// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class SloopStorageTests: XCTestCase {
    private var shared: URL!
    private var legacy: URL!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        shared = root.appendingPathComponent("shared")
        legacy = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: shared.deletingLastPathComponent())
    }

    func testFileNamesAreStableAcrossProcesses() {
        // Both the app and the extension derive these independently. If they
        // ever disagreed the extension would read an empty host list and
        // report every host as gone.
        XCTAssertEqual(SloopStorage.hostsFile(in: shared).lastPathComponent, "sloop-hosts.json")
        XCTAssertEqual(SloopStorage.knownHostsFile(in: shared).lastPathComponent,
                       "sloop-known-hosts.json")
    }

    func testEachDomainGetsItsOwnItemIndex() {
        let a = UUID(), b = UUID()
        XCTAssertNotEqual(SloopStorage.itemIndexFile(forDomain: a, in: shared),
                          SloopStorage.itemIndexFile(forDomain: b, in: shared))
        XCTAssertTrue(SloopStorage.itemIndexFile(forDomain: a, in: shared)
            .path.contains(a.uuidString))
    }

    /// The app's node and the extension's node are separate devices on the
    /// tailnet and must never share a state directory — one node key on two
    /// connections is a device that flaps between endpoints.
    func testTailnetRolesGetSeparateStateDirectories() throws {
        let app = try SloopStorage.tailnetStateDirectory(role: .app, in: shared)
        let files = try SloopStorage.tailnetStateDirectory(role: .fileProvider, in: shared)
        XCTAssertNotEqual(app, files)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.path))
    }

    // MARK: - Migration

    func testMigrationCopiesALegacyFileByteForByte() throws {
        let from = legacy.appendingPathComponent("sloop-hosts.json")
        let to = SloopStorage.hostsFile(in: shared)
        // A record this build cannot parse. Copying bytes rather than
        // re-encoding is what keeps it alive; HostStore preserves such records
        // deliberately and a decode/re-encode migration would drop them.
        let bytes = Data(#"[{"id":"x","futureKey":true}]"#.utf8)
        try bytes.write(to: from)

        XCTAssertTrue(try SloopStorage.migrateLegacyFile(from: from, to: to))
        XCTAssertEqual(try Data(contentsOf: to), bytes)
    }

    func testMigrationLeavesTheLegacyFileInPlace() throws {
        let from = legacy.appendingPathComponent("sloop-hosts.json")
        let to = SloopStorage.hostsFile(in: shared)
        try Data("[]".utf8).write(to: from)
        _ = try SloopStorage.migrateLegacyFile(from: from, to: to)
        XCTAssertTrue(FileManager.default.fileExists(atPath: from.path),
                      "the pre-migration copy is the user's only fallback if this went wrong")
    }

    /// Running twice must not overwrite what the shared container now holds —
    /// that would discard every host added since the migration.
    func testMigrationNeverOverwritesAnExistingSharedFile() throws {
        let from = legacy.appendingPathComponent("sloop-hosts.json")
        let to = SloopStorage.hostsFile(in: shared)
        try Data("legacy".utf8).write(to: from)
        try Data("current".utf8).write(to: to)

        XCTAssertFalse(try SloopStorage.migrateLegacyFile(from: from, to: to))
        XCTAssertEqual(try Data(contentsOf: to), Data("current".utf8))
    }

    func testMigrationWithNothingToMigrateIsNotAnError() throws {
        let from = legacy.appendingPathComponent("absent.json")
        let to = SloopStorage.hostsFile(in: shared)
        XCTAssertFalse(try SloopStorage.migrateLegacyFile(from: from, to: to))
        XCTAssertFalse(FileManager.default.fileExists(atPath: to.path))
    }

    func testMigrationCreatesTheDestinationDirectory() throws {
        let from = legacy.appendingPathComponent("sloop-hosts.json")
        let nested = shared.appendingPathComponent("does/not/exist")
        try Data("[]".utf8).write(to: from)
        XCTAssertTrue(try SloopStorage.migrateLegacyFile(
            from: from, to: SloopStorage.hostsFile(in: nested)))
    }

    // MARK: - App Group

    /// The nil-container path can't be induced here: only iOS returns nil for
    /// an unentitled group, while macOS hands back a `~/Library/Group
    /// Containers` path whether or not the entitlement exists. So the failure
    /// is asserted on the error itself — what it says is the whole reason it
    /// is thrown rather than silently swallowed.
    func testTheAppGroupFailureNamesTheEntitlementAndWhatItCosts() {
        let message = SloopStorage.StorageError
            .appGroupUnavailable("group.org.szatmary.sloop").localizedDescription
        XCTAssertTrue(message.contains("group.org.szatmary.sloop"), message)
        XCTAssertTrue(message.contains("App Group"), message)
        XCTAssertTrue(message.contains("entitlement"), message)
    }

    func testSharedDirectoryIsNamespacedInsideTheGroupContainer() throws {
        let directory = try SloopStorage.sharedDirectory(appGroup: "group.org.szatmary.sloop.test")
        XCTAssertEqual(directory.lastPathComponent, "Sloop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try? FileManager.default.removeItem(at: directory)
    }
}
