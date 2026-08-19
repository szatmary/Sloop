// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
import SloopKit
@testable import Sloop_macOS
@testable import SloopSSH

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

    /// The host decides whether it wants suggestions, and says no by giving
    /// the session no host to keep a history for.
    private func makeController(suggestions: Bool = true) -> TerminalController {
        TerminalController(makeTransport: { MessageTransport(message: "") },
                           appearance: .default,
                           suggestionsFor: suggestions ? host : nil,
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
        // A word at a time: `git st` proposes the word it completes to, and
        // accepting again would propose `--short` after it.
        XCTAssertEqual(controller.suggestions, ["git status"])
    }

    /// Accepting clears the line and types the whole command, so it lands
    /// correctly even when our model of what's on screen was wrong — which it
    /// can be after a history recall, where the line is inferred rather than
    /// observed.
    func testAcceptingASuggestionClearsTheLineFirst() throws {
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

    /// Pressing up recalls a command in the shell, and the shell never says
    /// which. Our own history is the same list in the same order, so the line
    /// is filled in from it and suggestions keep working while the recalled
    /// command is edited.
    func testPressingUpFillsTheLineFromHistory() throws {
        var history = CommandHistory()
        history.record("terraform plan")
        history.record("terraform apply -auto-approve")
        try store.save(history, for: host)

        let controller = makeController()
        controller.send(source: controller.terminalView, data: ArraySlice([0x1b, 0x5b, 0x41]))
        XCTAssertEqual(controller.typedLine, "terraform apply -auto-approve")

        controller.send(source: controller.terminalView, data: ArraySlice([0x1b, 0x5b, 0x41]))
        XCTAssertEqual(controller.typedLine, "terraform plan")
    }

    /// A host with suggestions off tracks nothing, suggests nothing, and
    /// writes nothing — the switch governs the recording, not just the display.
    func testAHostWithSuggestionsOffTracksNothing() throws {
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
