// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class ShellHistoryImporterTests: XCTestCase {
    func testPlainHistoryLinesComeThroughInOrder() {
        let commands = ShellHistoryImporter.commands(fromHistoryOutput: """
        cd /srv/app
        git pull
        systemctl restart app
        """)
        XCTAssertEqual(commands, ["cd /srv/app", "git pull", "systemctl restart app"])
    }

    /// zsh's extended history writes `: <started>:<elapsed>;command`, which is
    /// bookkeeping rather than anything anyone typed.
    func testZshExtendedHistoryMetadataIsStripped() {
        let commands = ShellHistoryImporter.commands(fromHistoryOutput: """
        : 1700000000:0;git status
        : 1700000005:12;make -j8
        """)
        XCTAssertEqual(commands, ["git status", "make -j8"])
    }

    /// A command that happens to start with ": " is a command, not metadata.
    func testALineThatMerelyLooksLikeMetadataIsKept() {
        let commands = ShellHistoryImporter.commands(fromHistoryOutput: ": echo hi; echo there")
        XCTAssertEqual(commands, [": echo hi; echo there"])
    }

    func testBlankLinesAreDropped() {
        XCTAssertEqual(ShellHistoryImporter.commands(fromHistoryOutput: "ls\n\n   \nps\n"),
                       ["ls", "ps"])
    }

    /// HISTFILE can point anywhere, including at something that isn't a history
    /// file at all.
    func testBinaryJunkIsNotOfferedAsACommand() {
        let commands = ShellHistoryImporter.commands(
            fromHistoryOutput: "ls\n\u{01}\u{02}\u{03}binary\nps")
        XCTAssertEqual(commands, ["ls", "ps"])
    }

    func testAHostWithNoHistoryProducesNothing() {
        XCTAssertEqual(ShellHistoryImporter.commands(fromHistoryOutput: ""), [])
        XCTAssertEqual(ShellHistoryImporter.commands(fromHistoryOutput: "\n\n"), [])
    }

    /// The command has to survive a host with no history files, an unset
    /// HISTFILE, and `set -e` — a failed read must not make the exec channel
    /// look like a failed connection.
    func testTheCommandCannotFail() {
        XCTAssertTrue(ShellHistoryImporter.command.hasSuffix("true"))
        XCTAssertTrue(ShellHistoryImporter.command.contains("2>/dev/null"))
        XCTAssertTrue(ShellHistoryImporter.command.contains(".zsh_history"))
        XCTAssertTrue(ShellHistoryImporter.command.contains(".bash_history"))
    }
}

extension ShellHistoryImporterTests {
    /// fish keeps a YAML-ish record: the command on a `- cmd:` line, and the
    /// lines below it describing when it ran and what paths it touched.
    func testFishHistoryYieldsCommandsWithoutItsBookkeeping() {
        let commands = ShellHistoryImporter.commands(fromHistoryOutput: """
        - cmd: git switch main
          when: 1700000000
        - cmd: cargo test
          when: 1700000060
          paths:
            - src/lib.rs
        """)
        XCTAssertEqual(commands, ["git switch main", "cargo test"])
    }

    /// HISTFILE is whatever the shell in use actually reads, so it is tried
    /// first — including for shells nobody listed.
    func testEveryCommonShellHasItsHistoryFileTried() {
        let command = ShellHistoryImporter.command
        XCTAssertTrue(command.contains("${HISTFILE:-}"))
        for file in ["/.zsh_history", "/.bash_history", "fish/fish_history",
                     "/.sh_history", "/.ash_history", "/.history", "nushell/history.txt"] {
            XCTAssertTrue(command.contains(file), "no attempt at \(file)")
        }
    }
}
