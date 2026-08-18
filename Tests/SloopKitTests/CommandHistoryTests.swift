// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class CommandHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func weeksAgo(_ weeks: Double) -> Date {
        now.addingTimeInterval(-weeks * 7 * 24 * 3600)
    }

    func testSuggestsCommandsSharingThePrefix() {
        var history = CommandHistory()
        history.record("git status", at: now)
        history.record("git rebase -i main", at: now)
        history.record("docker ps", at: now)
        XCTAssertEqual(Set(history.suggestions(for: "git", now: now)),
                       ["git status", "git rebase -i main"])
    }

    func testNeverSuggestsWhatIsAlreadyTyped() {
        var history = CommandHistory()
        history.record("make", at: now)
        XCTAssertEqual(history.suggestions(for: "make", now: now), [])
    }

    /// Frecency, not frequency: a command used constantly a month ago should
    /// lose to one used twice this morning, which is how a shell session
    /// actually feels.
    func testRecentBeatsMerelyFrequent() {
        var history = CommandHistory()
        for _ in 0..<40 { history.record("git status", at: weeksAgo(4)) }
        history.record("git rebase -i main", at: now)
        history.record("git rebase -i main", at: now)
        XCTAssertEqual(history.suggestions(for: "git", limit: 1, now: now), ["git rebase -i main"])
    }

    /// Same recency, so the count decides.
    func testFrequencyBreaksTiesAtEqualRecency() {
        var history = CommandHistory()
        history.record("npm run build", at: now)
        for _ in 0..<3 { history.record("npm run test", at: now) }
        XCTAssertEqual(history.suggestions(for: "npm", limit: 1, now: now), ["npm run test"])
    }

    func testImportedHistoryIsUsableImmediately() {
        var history = CommandHistory()
        history.importLines(["kubectl get pods", "kubectl logs -f api"], at: weeksAgo(1))
        XCTAssertEqual(history.suggestions(for: "kubectl l", limit: 1, now: now),
                       ["kubectl logs -f api"])
    }

    /// A line already typed here carries a real count and a real timestamp;
    /// the host's history file carries neither, so importing must not flatten
    /// what we know.
    func testImportDoesNotOverwriteWhatWasTypedHere() {
        var history = CommandHistory()
        for _ in 0..<5 { history.record("ssh zbox", at: now) }
        history.importLines(["ssh zbox"], at: weeksAgo(10))
        XCTAssertEqual(history.suggestions(for: "ssh z", limit: 1, now: now), ["ssh zbox"])
        // Still the five uses from today, not one from ten weeks ago.
        for _ in 0..<4 { history.record("ssh other", at: now) }
        XCTAssertEqual(history.suggestions(for: "ssh", limit: 1, now: now), ["ssh zbox"])
    }

    func testNewerImportedLinesOutrankOlderOnesAtTheSameScore() {
        var history = CommandHistory()
        // Shell history files are oldest-first, so the last line is the newest.
        history.importLines(["terraform plan", "terraform apply"], at: weeksAgo(1))
        XCTAssertEqual(history.suggestions(for: "terraform", limit: 1, now: now),
                       ["terraform apply"])
    }

    func testCompletionIsWhatIsLeftToType() {
        XCTAssertEqual(CommandHistory.completion(of: "git status", for: "git st"), "atus")
        XCTAssertNil(CommandHistory.completion(of: "git status", for: "git status"))
        XCTAssertNil(CommandHistory.completion(of: "ls", for: "git"))
    }

    func testEmptyPrefixSuggestsNothing() {
        var history = CommandHistory()
        history.record("ls -la", at: now)
        XCTAssertEqual(history.suggestions(for: "", now: now), [])
        XCTAssertEqual(history.suggestions(for: "   ", now: now), [])
    }

    func testSurvivesACodableRoundTrip() throws {
        var history = CommandHistory()
        history.record("git push --force-with-lease", at: now)
        let restored = try JSONDecoder().decode(
            CommandHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored.suggestions(for: "git p", now: now),
                       ["git push --force-with-lease"])
    }
}
