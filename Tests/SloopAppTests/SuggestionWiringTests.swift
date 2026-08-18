// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
import SloopKit
@testable import Sloop_macOS

/// The suggestion machinery is only as good as the bytes it sees, and the app
/// layer is where those come from. `CommandLineTracker` was fully tested and
/// still nothing appeared on screen, because typed characters went straight to
/// the transport and never reached it — a gap between two tested pieces, which
/// is where this kind of bug lives.
@MainActor
final class SuggestionWiringTests: XCTestCase {
    private var directory: URL!
    private var store: CommandHistoryStore!
    private let host = UUID()

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-wiring-\(UUID().uuidString)")
        store = CommandHistoryStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeController(suggestions: Bool = true) -> TerminalController {
        TerminalController(makeTransport: { MessageTransport(message: "") },
                           appearance: TerminalAppearance(suggestions: suggestions),
                           suggestionsFor: host,
                           historyStore: store)
    }

    /// What SwiftTerm hands the delegate when a key is tapped must reach the
    /// tracker. This is the path that was missing.
    func testTypingOnTheKeyboardReachesTheTracker() {
        let controller = makeController()
        for byte in Array("git st".utf8) {
            controller.send(source: controller.terminalView, data: ArraySlice([byte]))
        }
        XCTAssertEqual(controller.typedLine, "git st")
    }

    func testFinishedCommandsAreSuggestedNextTime() throws {
        var history = CommandHistory()
        history.record("git status --short")
        try store.save(history, for: host)

        let controller = makeController()
        for byte in Array("git st".utf8) {
            controller.send(source: controller.terminalView, data: ArraySlice([byte]))
        }
        XCTAssertEqual(controller.suggestions, ["git status --short"])
    }

    /// Accepting sends only the part not yet typed — the host must see the
    /// same keystrokes it would have got from a person finishing the line.
    func testAcceptingASuggestionSendsOnlyTheRemainder() throws {
        var history = CommandHistory()
        history.record("docker compose up -d")
        try store.save(history, for: host)

        let controller = makeController()
        for byte in Array("docker c".utf8) {
            controller.send(source: controller.terminalView, data: ArraySlice([byte]))
        }
        controller.acceptSuggestion("docker compose up -d")
        XCTAssertEqual(controller.typedLine, "docker compose up -d")
    }

    /// Off means off: nothing tracked, nothing suggested, nothing written.
    func testTheSettingStopsTrackingEntirely() throws {
        var history = CommandHistory()
        history.record("kubectl get pods")
        try store.save(history, for: host)

        let controller = makeController(suggestions: false)
        for byte in Array("kubectl g".utf8) {
            controller.send(source: controller.terminalView, data: ArraySlice([byte]))
        }
        XCTAssertEqual(controller.typedLine, "")
        XCTAssertEqual(controller.suggestions, [])
    }
}
