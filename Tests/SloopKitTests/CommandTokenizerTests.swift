// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class CommandTokenizerTests: XCTestCase {
    func testSplitsOnWhitespace() {
        XCTAssertEqual(CommandTokenizer.tokens("zpool status -v"), ["zpool", "status", "-v"])
        XCTAssertEqual(CommandTokenizer.tokens("  ls   -la  "), ["ls", "-la"])
        XCTAssertEqual(CommandTokenizer.tokens(""), [])
    }

    /// A quoted argument is one word. Splitting it would offer its insides as
    /// plausible next words, which they never are.
    func testQuotedArgumentsAreOneWord() {
        XCTAssertEqual(CommandTokenizer.tokens("git commit -m \"fix the thing\""),
                       ["git", "commit", "-m", "fix the thing"])
        XCTAssertEqual(CommandTokenizer.tokens("grep 'foo bar' file"),
                       ["grep", "foo bar", "file"])
    }

    func testQuotesInsideTheOtherKindAreLiteral() {
        XCTAssertEqual(CommandTokenizer.tokens("echo \"it's fine\""), ["echo", "it's fine"])
        XCTAssertEqual(CommandTokenizer.tokens("echo 'say \"hi\"'"), ["echo", "say \"hi\""])
    }

    func testBackslashQuotesTheNextCharacter() {
        XCTAssertEqual(CommandTokenizer.tokens("ls /very\\ long/path"), ["ls", "/very long/path"])
    }

    /// A line ending in a space is asking what comes next; anything else is
    /// still typing a word.
    func testContextSeparatesSettledWordsFromTheOneBeingTyped() {
        var context = CommandTokenizer.context("zpool sta")
        XCTAssertEqual(context.settled, ["zpool"])
        XCTAssertEqual(context.partial, "sta")

        context = CommandTokenizer.context("zpool ")
        XCTAssertEqual(context.settled, ["zpool"])
        XCTAssertEqual(context.partial, "")

        context = CommandTokenizer.context("zp")
        XCTAssertEqual(context.settled, [])
        XCTAssertEqual(context.partial, "zp")
    }
}
