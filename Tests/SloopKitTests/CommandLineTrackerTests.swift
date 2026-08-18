// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class CommandLineTrackerTests: XCTestCase {
    private func type(_ text: String, into tracker: inout CommandLineTracker) -> [String] {
        tracker.consume(ArraySlice(Array(text.utf8)))
    }

    func testBuildsTheLineAsItIsTyped() {
        var tracker = CommandLineTracker()
        _ = type("git st", into: &tracker)
        XCTAssertEqual(tracker.line, "git st")
        XCTAssertTrue(tracker.isCertain)
        XCTAssertTrue(tracker.isSuggestable)
    }

    func testBackspaceRemovesACharacter() {
        var tracker = CommandLineTracker()
        _ = type("lss", into: &tracker)
        _ = tracker.consume([0x7f])
        XCTAssertEqual(tracker.line, "ls")
    }

    func testReturnFinishesTheCommandAndStartsAFreshLine() {
        var tracker = CommandLineTracker()
        let finished = type("uptime\r", into: &tracker)
        XCTAssertEqual(finished, ["uptime"])
        XCTAssertEqual(tracker.line, "")
        XCTAssertTrue(tracker.isCertain)
    }

    /// A pasted block arrives as one write and runs several commands.
    func testAMultiLinePasteFinishesEachCommand() {
        var tracker = CommandLineTracker()
        let finished = type("cd /tmp\nls -la\n", into: &tracker)
        XCTAssertEqual(finished, ["cd /tmp", "ls -la"])
    }

    func testBlankLinesAreNotCommands() {
        var tracker = CommandLineTracker()
        XCTAssertEqual(type("\r", into: &tracker), [])
        XCTAssertEqual(type("   \r", into: &tracker), [])
    }

    func testControlCAbandonsTheLine() {
        var tracker = CommandLineTracker()
        _ = type("rm -rf /", into: &tracker)
        let finished = tracker.consume([0x03])
        XCTAssertEqual(finished, [])
        XCTAssertEqual(tracker.line, "")
        XCTAssertTrue(tracker.isCertain, "a cancelled line leaves us knowing exactly where we are")
    }

    func testControlUClearsTheLineAndControlWTheLastWord() {
        var tracker = CommandLineTracker()
        _ = type("git commit -m", into: &tracker)
        _ = tracker.consume([0x17])
        XCTAssertEqual(tracker.line, "git commit ")
        _ = tracker.consume([0x15])
        XCTAssertEqual(tracker.line, "")
        XCTAssertTrue(tracker.isCertain)
    }

    /// The host performs tab completion, and we never see what it expanded to —
    /// so from here on the line on screen is not the line we have.
    func testTabMakesTheLineUncertain() {
        var tracker = CommandLineTracker()
        _ = type("cd /usr/lo", into: &tracker)
        _ = tracker.consume([0x09])
        XCTAssertFalse(tracker.isCertain)
        XCTAssertFalse(tracker.isSuggestable)
    }

    /// Arrow keys move the cursor; anything typed after lands somewhere we
    /// aren't tracking.
    func testArrowKeysMakeTheLineUncertain() {
        var tracker = CommandLineTracker()
        _ = type("echo hello", into: &tracker)
        _ = tracker.consume(ArraySlice([0x1b, 0x5b, 0x44]))   // ESC [ D — left
        XCTAssertFalse(tracker.isCertain)
    }

    /// An uncertain line must not be offered as the basis for a completion,
    /// and finishing it must not teach the history something wrong.
    func testAnUncertainLineIsNeverRecorded() {
        var tracker = CommandLineTracker()
        _ = type("cd /usr/lo", into: &tracker)
        _ = tracker.consume([0x09])
        let finished = type("cal\r", into: &tracker)
        XCTAssertEqual(finished, [], "we don't know what the host completed, so we don't know what ran")
        XCTAssertTrue(tracker.isCertain, "the next line starts clean")
    }

    func testTrustIsRestoredAfterTheLineEnds() {
        var tracker = CommandLineTracker()
        _ = tracker.consume([0x09])
        XCTAssertFalse(tracker.isCertain)
        _ = type("\r", into: &tracker)
        XCTAssertTrue(tracker.isCertain)
    }

    /// One character is not a prefix worth completing, and a line ending in a
    /// space is asking for the *next* word, which history-by-prefix can't
    /// answer.
    func testShortAndTrailingSpaceLinesAreNotSuggestable() {
        var tracker = CommandLineTracker()
        _ = type("l", into: &tracker)
        XCTAssertFalse(tracker.isSuggestable)
        _ = type("s ", into: &tracker)
        XCTAssertFalse(tracker.isSuggestable)
    }

    func testInvalidateDropsTrustWithoutLosingTheLine() {
        var tracker = CommandLineTracker()
        _ = type("top", into: &tracker)
        tracker.invalidate()
        XCTAssertEqual(tracker.line, "top")
        XCTAssertFalse(tracker.isSuggestable)
    }
}
