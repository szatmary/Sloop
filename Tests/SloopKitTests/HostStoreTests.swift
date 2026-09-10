// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class HostStoreTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hoststore-\(UUID().uuidString).json")
    }

    /// Two records this build can't read: one that isn't a host at all, and
    /// one written by a newer build with a connection method this one has
    /// never heard of. Neither may take the whole list down with it.
    private let mixedFile = """
    [
      {"id":"6F1E2D3C-0000-0000-0000-000000000001","alias":"good",
       "hostname":"a.example.com","port":22,"username":"matt",
       "auth":{"password":{}},"useMosh":false},
      {"this is": "not a host"},
      {"id":"6F1E2D3C-0000-0000-0000-000000000002","alias":"future",
       "hostname":"b.example.com","port":22,"username":"matt",
       "auth":{"password":{}},"useMosh":false,
       "connectionMethod":"wireguard"}
    ]
    """

    func testSkipsUndecodableHostsInsteadOfWipingTheList() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(mixedFile.utf8).write(to: url)
        let store = HostStore(fileURL: url)
        XCTAssertEqual(store.hosts.map(\.alias), ["good"])
    }

    /// The delayed half of the same bug. Skipping a record on load was never
    /// the loss — the loss came later, when the next unrelated save rewrote
    /// the file without it, permanently deleting a host the user still had.
    /// The record has to survive a write it played no part in.
    func testUnreadableRecordsSurviveALaterUnrelatedSave() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(mixedFile.utf8).write(to: url)

        let store = HostStore(fileURL: url)
        try store.upsert(SSHHost(alias: "brand new", hostname: "c.example.com", username: "matt"))

        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let records = try XCTUnwrap(raw as? [[String: Any]])
        XCTAssertEqual(records.count, 4, "the two unreadable records must still be there")
        XCTAssertTrue(records.contains { $0["this is"] as? String == "not a host" })
        XCTAssertTrue(records.contains { $0["connectionMethod"] as? String == "wireguard" },
                      "a host written by a newer build must survive this build touching the file")

        // And the build that can read them gets them back intact — the point
        // of keeping them at all.
        let future = try XCTUnwrap(records.first { $0["connectionMethod"] as? String == "wireguard" })
        XCTAssertEqual(future["alias"] as? String, "future")
        XCTAssertEqual(future["hostname"] as? String, "b.example.com")
    }

    /// Deleting a host must not resurrect the records around it, and removing
    /// the last readable host must not take them with it either.
    func testUnreadableRecordsSurviveARemove() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(mixedFile.utf8).write(to: url)

        let store = HostStore(fileURL: url)
        try store.remove(try XCTUnwrap(store.hosts.first))

        let records = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.contains { $0["connectionMethod"] as? String == "wireguard" })
    }

    /// Deleting a host this build *can't* read must actually delete it. The
    /// user asked; carrying the record through anyway would make the host
    /// immortal, and it is only reachable by id.
    func testRemovingAHostAlsoRemovesAnUnreadableRecordWithTheSameID() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(mixedFile.utf8).write(to: url)

        let store = HostStore(fileURL: url)
        let futureID = try XCTUnwrap(UUID(uuidString: "6F1E2D3C-0000-0000-0000-000000000002"))
        try store.remove(SSHHost(id: futureID, alias: "future", hostname: "b.example.com",
                             username: "matt"))

        let records = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertFalse(records.contains { $0["connectionMethod"] as? String == "wireguard" })
        XCTAssertTrue(records.contains { $0["this is"] as? String == "not a host" },
                      "the unrelated record must be left alone")
    }

    /// A file that can't be parsed at all is the same loss on a bigger scale.
    /// It gets moved aside, not overwritten — and the app keeps working,
    /// which "refuse to save anything ever again" would not.
    func testUnparseableFileIsMovedAsideRatherThanOverwritten() throws {
        let url = tempFile()
        let quarantine = url.appendingPathExtension("unreadable")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: quarantine)
        }
        try Data("{ this is not a host list".utf8).write(to: url)

        let store = HostStore(fileURL: url)
        XCTAssertTrue(store.hosts.isEmpty)
        try store.upsert(SSHHost(alias: "new", hostname: "n.example.com", username: "matt"))

        XCTAssertEqual(try String(contentsOf: quarantine, encoding: .utf8),
                       "{ this is not a host list",
                       "the unreadable file must survive verbatim for hand recovery")
        XCTAssertEqual(HostStore(fileURL: url).hosts.map(\.alias), ["new"],
                       "and the store must be usable again afterwards")
    }

    /// A zero-byte file is damage — an interrupted or out-of-space write —
    /// not a fresh install, and gets the same protection.
    func testEmptyFileIsTreatedAsDamage() throws {
        let url = tempFile()
        let quarantine = url.appendingPathExtension("unreadable")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: quarantine)
        }
        try Data().write(to: url)

        let store = HostStore(fileURL: url)
        try store.upsert(SSHHost(alias: "new", hostname: "n.example.com", username: "matt"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }

    /// A missing file is a fresh install, and must not be quarantined or
    /// otherwise fussed over.
    func testMissingFileIsAFreshInstall() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostStore(fileURL: url)
        XCTAssertTrue(store.hosts.isEmpty)

        try store.upsert(SSHHost(alias: "first", hostname: "f.example.com", username: "matt"))
        XCTAssertEqual(HostStore(fileURL: url).hosts.map(\.alias), ["first"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("unreadable").path))
    }

    /// A directory the store cannot write into, holding a file it cannot read:
    /// the quarantine move fails, so `save()` refuses rather than overwrite the
    /// user's only copy.
    private func storeThatCannotSave() throws -> (HostStore, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoststore-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("hosts.json")
        try Data("{ this is not a host list".utf8).write(to: url)

        let store = HostStore(fileURL: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)
        return (store, {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    /// `upsert` swallowed this with `try?`. The list then showed a host the
    /// file never received, and the next launch showed it gone — reintroducing,
    /// one line later, exactly the silent loss the quarantine design exists to
    /// prevent.
    func testUpsertReportsAFailedSave() throws {
        let (store, cleanup) = try storeThatCannotSave()
        defer { cleanup() }

        XCTAssertThrowsError(
            try store.upsert(SSHHost(alias: "new", hostname: "n.example.com", username: "matt"))
        )
    }

    /// Same for delete: "it's gone" is a worse lie than "it didn't save".
    func testRemoveReportsAFailedSave() throws {
        let (store, cleanup) = try storeThatCannotSave()
        defer { cleanup() }

        XCTAssertThrowsError(
            try store.remove(SSHHost(alias: "gone", hostname: "g.example.com", username: "matt"))
        )
    }

    /// A refused write must leave nothing behind in memory. Otherwise the next
    /// save that *does* succeed — some unrelated edit, minutes later — carries
    /// the rejected change to disk with it, turning a reported failure into a
    /// silent success.
    func testAFailedUpsertLeavesTheListUnchanged() throws {
        let (store, cleanup) = try storeThatCannotSave()
        defer { cleanup() }
        let before = store.hosts.map(\.id)

        XCTAssertThrowsError(
            try store.upsert(SSHHost(alias: "new", hostname: "n.example.com", username: "matt"))
        )

        XCTAssertEqual(store.hosts.map(\.id), before)
    }

    func testRoundTripSurvives() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostStore(fileURL: url)
        try store.upsert(SSHHost(alias: "t", hostname: "h", username: "u",
                             connectionMethod: .cloudflareAccess))
        let reloaded = HostStore(fileURL: url)
        XCTAssertEqual(reloaded.hosts.first?.connectionMethod, .cloudflareAccess)
    }
}
