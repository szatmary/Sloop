// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class CommandHistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: CommandHistoryStore!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-history-\(UUID().uuidString)")
        store = CommandHistoryStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testHistorySurvivesARelaunch() throws {
        let host = UUID()
        var history = CommandHistory()
        history.record("tail -f /var/log/syslog")
        try store.save(history, for: host)

        let reopened = CommandHistoryStore(directory: directory)
        XCTAssertEqual(reopened.history(for: host).suggestions(for: "tail", limit: 1),
                       ["tail -f"])
    }

    /// One host's commands must never be offered on another. They are a record
    /// of what someone did on a particular machine, and the wrong machine is
    /// both useless and revealing.
    func testHostsDoNotSeeEachOthersHistory() throws {
        let (first, second) = (UUID(), UUID())
        var history = CommandHistory()
        history.record("kubectl delete pod api-7f9")
        try store.save(history, for: first)
        XCTAssertTrue(store.history(for: second).isEmpty)
    }

    func testAnUnknownHostStartsEmptyRatherThanFailing() {
        XCTAssertTrue(store.history(for: UUID()).isEmpty)
    }

    /// "Clear history" has to actually remove the file, or it isn't worth
    /// offering.
    func testForgettingDeletesTheFile() throws {
        let host = UUID()
        var history = CommandHistory()
        history.record("psql -h db.internal -U admin")
        try store.save(history, for: host)
        try store.forget(host: host)

        XCTAssertTrue(store.history(for: host).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(host.uuidString).json").path))
    }

    func testForgettingAHostWithNoHistoryIsNotAnError() {
        XCTAssertNoThrow(try store.forget(host: UUID()))
    }

    /// A damaged file costs the user nothing here — the history rebuilds itself
    /// from ordinary use — so it starts over rather than leaving suggestions
    /// broken until someone finds a file they never knew about.
    func testACorruptFileStartsOverInsteadOfStayingBroken() throws {
        let host = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("\(host.uuidString).json"))

        XCTAssertTrue(store.history(for: host).isEmpty)

        var history = CommandHistory()
        history.record("uptime")
        XCTAssertNoThrow(try store.save(history, for: host))
        XCTAssertEqual(store.history(for: host).suggestions(for: "up", limit: 1), ["uptime"])
    }
}
