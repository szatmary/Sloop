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
        _ = type("cd /usr/lo", into: &tracker)
        _ = tracker.consume([0x09])
        XCTAssertFalse(tracker.isCertain)
        _ = type("\r", into: &tracker)
        XCTAssertTrue(tracker.isCertain)
    }

    /// An empty line has nothing to rank against; everything else does,
    /// including a line ending in a space — "what comes after `zpool `" is the
    /// question a next-word model answers best.
    func testAnythingTypedIsSuggestableButNothingIsNot() {
        var tracker = CommandLineTracker()
        XCTAssertFalse(tracker.isSuggestable)
        _ = type("l", into: &tracker)
        XCTAssertTrue(tracker.isSuggestable)
        _ = type("s ", into: &tracker)
        XCTAssertTrue(tracker.isSuggestable)
    }

    func testInvalidateDropsTrustWithoutLosingTheLine() {
        var tracker = CommandLineTracker()
        _ = type("top", into: &tracker)
        tracker.invalidate()
        XCTAssertEqual(tracker.line, "top")
        XCTAssertFalse(tracker.isSuggestable)
    }
}

extension CommandLineTrackerTests {
    /// A terminal answers the host's queries — device attributes, cursor
    /// position — through the same path as typing, and those answers are escape
    /// sequences. They arrive before anyone has touched a key, so treating them
    /// as "something happened we can't model" wrote the line off as
    /// untrustworthy for the rest of the session. This is what stopped the
    /// suggestion bar ever appearing.
    func testTerminalRepliesBeforeTypingDoNotPoisonTheLine() {
        var tracker = CommandLineTracker()
        tracker.consume(ArraySlice([0x1b, 0x5b, 0x3f, 0x31, 0x3b, 0x32, 0x63]))  // ESC[?1;2c
        tracker.consume(ArraySlice([0x1b, 0x5b, 0x32, 0x34, 0x3b, 0x38, 0x30, 0x52])) // ESC[24;80R
        _ = tracker.consume(ArraySlice(Array("zpool status".utf8)))
        XCTAssertTrue(tracker.isCertain)
        XCTAssertTrue(tracker.isSuggestable)
        XCTAssertEqual(tracker.line, "zpool status")
    }

    /// The exception is only for an empty line: once there is text, an
    /// unmodelled key really can leave us describing something that isn't on
    /// screen.
    func testAnUnmodelledKeyStillPoisonsALineWithTextOnIt() {
        var tracker = CommandLineTracker()
        _ = tracker.consume(ArraySlice(Array("zpool".utf8)))
        tracker.consume(ArraySlice([0x1b, 0x5b, 0x44]))   // left arrow
        XCTAssertFalse(tracker.isCertain)
    }
}

extension CommandLineTrackerTests {
    /// The shell asks the terminal questions while you type — where is the
    /// cursor, what are you, did focus change — and the answers leave through
    /// the same channel as typing. Treating them as unmodelled keys made the
    /// suggestion bar appear and vanish a moment later, over and over.
    func testTerminalRepliesDoNotDisturbALineBeingTyped() {
        var tracker = CommandLineTracker()
        _ = type("zpool sta", into: &tracker)
        tracker.consume(ArraySlice([0x1b, 0x5b, 0x32, 0x34, 0x3b, 0x31, 0x30, 0x52])) // ESC[24;10R
        tracker.consume(ArraySlice([0x1b, 0x5b, 0x49]))                                // ESC[I focus
        tracker.consume(ArraySlice([0x1b, 0x5b, 0x3f, 0x36, 0x32, 0x3b, 0x63]))        // ESC[?62;c
        XCTAssertTrue(tracker.isCertain)
        XCTAssertEqual(tracker.line, "zpool sta")
        _ = type("tus", into: &tracker)
        XCTAssertEqual(tracker.line, "zpool status")
    }

    /// A reply arriving mid-sequence must not swallow what follows it.
    func testTypingContinuesAfterAReplyInTheSameWrite() {
        var tracker = CommandLineTracker()
        _ = tracker.consume(ArraySlice([0x1b, 0x5b, 0x49] + Array("ls -la".utf8)))
        XCTAssertEqual(tracker.line, "ls -la")
        XCTAssertTrue(tracker.isCertain)
    }
}

extension CommandLineTrackerTests {
    /// The first keystroke is a real prefix, and on a host where only one
    /// command starts with `z` it is the most useful moment there is.
    func testASingleCharacterIsSuggestable() {
        var tracker = CommandLineTracker()
        _ = type("z", into: &tracker)
        XCTAssertTrue(tracker.isSuggestable)
    }
}
