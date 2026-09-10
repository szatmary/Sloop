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

/// Reading the host's own shell history, so suggestions are useful on the first
/// connection rather than the second week.
///
/// It used to arrive two different ways — `runOnSession` for an SSH session,
/// and a history-shaped callback on `MoshOrSSHTransport` that the controller
/// reached by casting to it — which meant the feature worked only for the two
/// transport shapes somebody had remembered to write a path for. Now there is
/// one: ask the transport, before starting it, and let it decide when it can
/// afford to.
extension SuggestionWiringTests {
    /// Answers one question about the host, and remembers whether it was asked
    /// in time — a Mosh session can only carry a question registered before
    /// `start()`, because its bootstrap exec is built there.
    private final class HistoryTransport: Transport, SessionCommandRunner {
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onOpen: (() -> Void)?
        var onClose: ((Error?) -> Void)?
        private let answer: String?
        private(set) var started = false
        private(set) var askedAfterStart = false
        private(set) var requested: String?

        init(answering answer: String?) { self.answer = answer }

        func start() { started = true }
        func send(_ bytes: ArraySlice<UInt8>) {}
        func resize(cols: Int, rows: Int) {}
        func close() {}

        func requestOnSession(_ command: String, completion: @escaping (String?) -> Void) {
            if started { askedAfterStart = true }
            requested = command
            completion(answer)
        }
    }

    /// Lets the main queue run what `CommandSuggester` posted to it. The import
    /// lands on the main thread because it mutates published state.
    private func drainMainQueue() {
        let settled = expectation(description: "main queue settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
    }

    func testTheHostsShellHistoryIsLearnedOverAnyTransportThatCanAnswer() {
        let transport = HistoryTransport(answering: "git status --short\nmake -j8\n")
        let controller = TerminalController(makeTransport: { transport },
                                            appearance: .default,
                                            suggestionsFor: host,
                                            historyStore: store)
        drainMainQueue()

        for byte in Array("git st".utf8) {
            controller.send(source: controller.terminalView, data: ArraySlice([byte]))
        }
        XCTAssertEqual(controller.suggestions, ["git status"],
                       "the host's own history should be suggestable on the first connection")
    }

    /// Registered before the transport starts, which is the only moment a Mosh
    /// session can still fold the question into its bootstrap.
    func testTheHistoryIsAskedForBeforeTheTransportStarts() {
        let transport = HistoryTransport(answering: "")
        _ = TerminalController(makeTransport: { transport },
                               appearance: .default,
                               suggestionsFor: host,
                               historyStore: store)
        XCTAssertNotNil(transport.requested)
        XCTAssertFalse(transport.askedAfterStart,
                       "a session that asks after starting can never carry the question on a Mosh bootstrap")
    }

    /// A host with suggestions off is never asked. The switch governs whether
    /// the host's history is opened at all, not merely what is shown.
    func testAHostWithSuggestionsOffIsNeverAskedForItsHistory() {
        let transport = HistoryTransport(answering: "kubectl get pods\n")
        _ = TerminalController(makeTransport: { transport },
                               appearance: .default,
                               suggestionsFor: nil,
                               historyStore: store)
        XCTAssertNil(transport.requested)
    }
}

/// Echo confirmation, end to end at the app layer.
///
/// The tracker's own tests prove it can tell an echoed line from an unechoed
/// one. This proves the controller actually gives it the bytes to tell with:
/// `transport.onData` has to reach the suggester, and until 2026-09-10 it did
/// not — which is the whole of finding A1. A gap between two tested pieces.
extension SuggestionWiringTests {
    /// A transport whose output the test drives, so echo can be interleaved
    /// with typing the way a real shell interleaves it.
    private final class EchoableTransport: Transport {
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onOpen: (() -> Void)?
        var onClose: ((Error?) -> Void)?
        func start() { onOpen?() }
        func send(_ bytes: ArraySlice<UInt8>) {}
        func resize(cols: Int, rows: Int) {}
        func close() {}

        /// The host writing back.
        func emit(_ text: String) { onData?(ArraySlice(Array(text.utf8))) }
    }

    private func makeEchoableController() -> (TerminalController, EchoableTransport) {
        let transport = EchoableTransport()
        let controller = TerminalController(makeTransport: { transport },
                                            appearance: .default,
                                            suggestionsFor: host,
                                            historyStore: store)
        return (controller, transport)
    }

    private func type(_ text: String, on controller: TerminalController) {
        for byte in Array(text.utf8) {
            controller.send(source: controller.terminalView, data: ArraySlice([byte]))
        }
    }

    func testACommandTheHostEchoedIsRecorded() {
        let (controller, transport) = makeEchoableController()
        type("uptime", on: controller)
        transport.emit("uptime")
        drainMainQueue()
        type("\r", on: controller)

        XCTAssertEqual(store.history(for: host).commands, ["uptime"])
    }

    /// The one that matters. `sudo` turns echo off, so nothing typed comes
    /// back — and nothing may be written.
    func testAPasswordTypedAtAnEchoOffPromptIsNeverWritten() {
        let (controller, transport) = makeEchoableController()
        transport.emit("[sudo] password for matt: ")
        drainMainQueue()
        type("hunter2\r", on: controller)

        XCTAssertEqual(store.history(for: host).commands, [],
                       "a password must not reach the history file")
    }
}
