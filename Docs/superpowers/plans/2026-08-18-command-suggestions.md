# Command Suggestions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Suggest the next shell command above the keyboard, built from a history Sloop assembles by reading the terminal screen, ranked and extended by an on-device model.

**Architecture:** The durable, order-dependent logic (`CommandHistory`, its store) is pure and lives in SloopKit, where `swift test` reaches it on both macOS and Linux. Everything touching Foundation Models lives in the app layer behind an availability gate and takes text in / values out, so it can be driven from the macOS app without any iOS UI. Capture reads the screen via SwiftTerm's public `Terminal.getText`; nothing reads keystrokes.

**Tech Stack:** Swift 5.9+, SwiftUI + UIKit, SwiftTerm, FoundationModels (iOS 26 / macOS 26), XCTest, XcodeGen.

**Spec:** `Docs/superpowers/specs/2026-08-18-command-suggestions-design.md`

## Global Constraints

- **License header** — every new `.swift` file under `Sources/`, `App/`, `Tests/` starts with exactly:
  ```swift
  // Sloop — Copyright (C) 2026 Matthew Szatmary
  // GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md
  ```
- **`Sources/SloopKit` must never import FoundationModels, UIKit, SwiftUI, or SwiftTerm.** CI now runs `swift test` on `ubuntu-latest`; a platform import there breaks the Linux job. SloopKit is Foundation-only.
- **Read the screen, never the keystrokes.** Command text comes from `Terminal.getText`. Capturing typed bytes would record passwords — echo suppression is a remote termios setting the client is never told about, so there is no reliable guard. The screen cannot contain what was never echoed.
- **A command whose line begins with a space is never recorded** (`HISTCONTROL=ignorespace` convention).
- **Suggestions insert; they never execute.** No path may auto-accept, auto-run, or run a command on a single tap.
- **Screen text is never persisted.** Only extracted commands reach disk.
- **Deployment targets stay at iOS 17 / macOS 14.** Everything model-related is `#available`-gated inside them; do not raise the app's floor.
- **Test command:** `swift test` from the repo root. Filter with `swift test --filter <TestClassName>`.
- **No project.yml changes needed** — `App/Sloop` is globbed by path, and `Sources/SloopKit` is globbed by SwiftPM.

---

### Task 1: `CommandHistory` — the pure list

**Files:**
- Create: `Sources/SloopKit/Terminal/CommandHistory.swift`
- Test: `Tests/SloopKitTests/CommandHistoryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `CommandHistory` (a `Codable`, `Equatable`, `Sendable` struct) with `entries: [Entry]`, `record(_:at:)`, `ranked(matching:limit:)`, `contains(_:)`, `purge()`, and the nested `CommandHistory.Entry` (`command`, `lastUsed`, `useCount`). Tasks 2, 4, 5, 6 all consume these.

- [ ] **Step 1: Write the failing test**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class CommandHistoryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRecordingAddsACommand() {
        var history = CommandHistory()
        history.record("ls -la", at: t0)
        XCTAssertEqual(history.entries.map(\.command), ["ls -la"])
        XCTAssertEqual(history.entries.first?.useCount, 1)
    }

    func testRecordingTheSameCommandCountsItRatherThanDuplicating() {
        var history = CommandHistory()
        history.record("git status", at: t0)
        history.record("git status", at: t0.addingTimeInterval(60))
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries.first?.useCount, 2)
        XCTAssertEqual(history.entries.first?.lastUsed, t0.addingTimeInterval(60))
    }

    /// The escape hatch people already use with HISTCONTROL=ignorespace: a
    /// leading space means "do not remember this one".
    func testALeadingSpaceMeansDoNotRecord() {
        var history = CommandHistory()
        history.record(" mysql -pSECRET", at: t0)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testBlankAndWhitespaceOnlyCommandsAreIgnored() {
        var history = CommandHistory()
        history.record("", at: t0)
        history.record("   ", at: t0)
        history.record("\t\n", at: t0)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testRecordingTrimsTrailingWhitespace() {
        var history = CommandHistory()
        history.record("ls -la   ", at: t0)
        XCTAssertEqual(history.entries.first?.command, "ls -la")
    }

    // MARK: Ranking

    // Every ranking test passes `now:` explicitly. Letting it default to
    // `Date()` makes the ages ~56 years for a 1970 fixture date, which drives
    // every recency term to ~0 — equal-count entries then score identically and
    // `sorted(by:)` is not guaranteed stable, so the test would pass or fail on
    // a coin flip.

    func testRankingPrefersMoreRecentAmongEqualCounts() {
        var history = CommandHistory()
        history.record("older", at: t0)
        history.record("newer", at: t0.addingTimeInterval(3600))
        XCTAssertEqual(
            history.ranked(matching: "", limit: 10, now: t0.addingTimeInterval(7200))
                .map(\.command),
            ["newer", "older"])
    }

    func testRankingPrefersMoreUsedAmongEqualRecency() {
        var history = CommandHistory()
        history.record("once", at: t0)
        history.record("twice", at: t0)
        history.record("twice", at: t0)
        XCTAssertEqual(
            history.ranked(matching: "", limit: 10, now: t0.addingTimeInterval(3600))
                .first?.command,
            "twice")
    }

    /// Frecency, not pure recency: something used constantly should outrank a
    /// one-off typed slightly more recently. `now` is close to both timestamps
    /// so the recency terms genuinely differ and frequency has to do the work.
    func testFrequencyCanOutweighASlightlyMoreRecentOneOff() {
        var history = CommandHistory()
        for i in 0..<10 {
            history.record("git status", at: t0.addingTimeInterval(Double(i) * 60))
        }
        history.record("some-one-off", at: t0.addingTimeInterval(700))
        XCTAssertEqual(
            history.ranked(matching: "", limit: 10, now: t0.addingTimeInterval(800))
                .first?.command,
            "git status")
    }

    func testRankingFiltersByPrefix() {
        var history = CommandHistory()
        history.record("git status", at: t0)
        history.record("git commit -m wip", at: t0)
        history.record("ls -la", at: t0)
        let matches = history.ranked(matching: "git ", limit: 10).map(\.command)
        XCTAssertEqual(Set(matches), ["git status", "git commit -m wip"])
    }

    func testRankingRespectsTheLimit() {
        var history = CommandHistory()
        for i in 0..<20 { history.record("cmd\(i)", at: t0) }
        XCTAssertEqual(history.ranked(matching: "", limit: 5).count, 5)
    }

    // MARK: Cap

    func testTheCapEvictsTheLeastValuableEntry() {
        var history = CommandHistory(capacity: 3)
        history.record("keep-a", at: t0)
        history.record("keep-a", at: t0)          // useCount 2
        history.record("keep-b", at: t0.addingTimeInterval(1000))
        history.record("evict-me", at: t0)        // once, oldest
        history.record("keep-c", at: t0.addingTimeInterval(2000))

        XCTAssertEqual(history.entries.count, 3)
        XCTAssertFalse(history.contains("evict-me"))
        XCTAssertTrue(history.contains("keep-a"))
        XCTAssertTrue(history.contains("keep-c"))
    }

    func testPurgeEmptiesTheHistory() {
        var history = CommandHistory()
        history.record("ls", at: t0)
        history.purge()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testCodableRoundTrip() throws {
        var history = CommandHistory(capacity: 7)
        history.record("ls -la", at: t0)
        history.record("ls -la", at: t0.addingTimeInterval(5))
        let decoded = try JSONDecoder().decode(
            CommandHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandHistoryTests`
Expected: FAIL — `cannot find 'CommandHistory' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// The commands seen on one host, most useful first.
///
/// This is the snippet library, and the reason it never needs curating: every
/// command you have run is a command you might run again. Pure and
/// Foundation-only — the model that extracts commands and the UI that shows
/// them both live elsewhere, so this stays testable on Linux.
public struct CommandHistory: Codable, Equatable, Sendable {

    public struct Entry: Codable, Equatable, Sendable {
        public let command: String
        public internal(set) var lastUsed: Date
        public internal(set) var useCount: Int
    }

    public private(set) var entries: [Entry]
    /// The most commands to keep. Old, rarely-used entries are evicted rather
    /// than letting a long-lived host grow the file without bound.
    public let capacity: Int

    public init(entries: [Entry] = [], capacity: Int = 500) {
        self.entries = entries
        self.capacity = capacity
    }

    /// Record a command that was run. Ignores anything blank, and anything
    /// whose line began with a space — the `HISTCONTROL=ignorespace`
    /// convention, and the user's escape hatch for a command with a secret in
    /// its arguments.
    public mutating func record(_ raw: String, at date: Date = Date()) {
        guard !raw.hasPrefix(" ") else { return }
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        if let index = entries.firstIndex(where: { $0.command == command }) {
            entries[index].useCount += 1
            entries[index].lastUsed = max(entries[index].lastUsed, date)
        } else {
            entries.append(Entry(command: command, lastUsed: date, useCount: 1))
        }
        evictIfNeeded(now: date)
    }

    public func contains(_ command: String) -> Bool {
        entries.contains { $0.command == command }
    }

    /// The best candidates, most useful first. `prefix` filters the way shell
    /// history search does; pass "" for everything.
    public func ranked(matching prefix: String, limit: Int, now: Date = Date()) -> [Entry] {
        entries
            .filter { prefix.isEmpty || $0.command.hasPrefix(prefix) }
            .sorted { score($0, now: now) > score($1, now: now) }
            .prefix(limit)
            .map { $0 }
    }

    public mutating func purge() {
        entries.removeAll()
    }

    // MARK: - Private

    /// Frecency: usage weighted by how recently it was last seen, so a command
    /// you run constantly beats a one-off typed slightly more recently, but a
    /// command you have abandoned decays out of the way.
    private func score(_ entry: Entry, now: Date) -> Double {
        let ageInHours = max(now.timeIntervalSince(entry.lastUsed), 0) / 3600
        let recency = 1.0 / (1.0 + ageInHours)
        return Double(entry.useCount) * (0.25 + recency)
    }

    private mutating func evictIfNeeded(now: Date) {
        guard entries.count > capacity else { return }
        entries.sort { score($0, now: now) > score($1, now: now) }
        entries.removeLast(entries.count - capacity)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CommandHistoryTests`
Expected: PASS, 13 tests.

If `testFrequencyCanOutweighASlightlyMoreRecentOneOff` fails, the frecency weighting is wrong, not the test — a command used ten times must beat a single use from a few minutes later. Adjust the constant in `score`, not the assertion.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS — everything that passed before, plus 13.

- [ ] **Step 6: Commit**

```bash
git add Sources/SloopKit/Terminal/CommandHistory.swift Tests/SloopKitTests/CommandHistoryTests.swift
git commit -m "SloopKit: a command history that ranks by frecency"
```

---

### Task 2: `CommandHistoryStore` — per-host persistence

**Files:**
- Create: `Sources/SloopKit/Terminal/CommandHistoryStore.swift`
- Test: `Tests/SloopKitTests/CommandHistoryStoreTests.swift`

**Interfaces:**
- Consumes: `CommandHistory` (Task 1). Hosts are keyed by `UUID` (which is what
  `SSHHost.ID` resolves to) — the store deliberately does not depend on
  `SSHHost` itself.
- Produces: `CommandHistoryStore` with `init(directoryURL:)`, `history(for:) -> CommandHistory`, `record(_:for:at:)`, `purge(for:)`, `purgeAll()`. Tasks 4, 5, 6, 7 consume these.

Follows `HostStore`'s shape (JSON in Application Support, injectable location for tests) with one deliberate difference: the file is written with `FileProtectionType.complete`, so it is encrypted at rest whenever the device is locked. `HostStore` does not do this because a host list is not sensitive; a command history is — it carries internal hostnames, paths, and occasionally a secret in an argument.

- [ ] **Step 1: Write the failing test**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class CommandHistoryStoreTests: XCTestCase {

    private var directory: URL!
    private let hostA = UUID()
    private let hostB = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("command-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnUnknownHostHasAnEmptyHistory() {
        let store = CommandHistoryStore(directoryURL: directory)
        XCTAssertTrue(store.history(for: hostA).entries.isEmpty)
    }

    func testRecordedCommandsSurviveAFreshStore() {
        let store = CommandHistoryStore(directoryURL: directory)
        store.record("ls -la", for: hostA, at: t0)

        let reopened = CommandHistoryStore(directoryURL: directory)
        XCTAssertEqual(reopened.history(for: hostA).entries.map(\.command), ["ls -la"])
    }

    /// Suggestions are per host: what you run on the build box should not be
    /// offered on the database box.
    func testHistoriesAreIsolatedPerHost() {
        let store = CommandHistoryStore(directoryURL: directory)
        store.record("make deploy", for: hostA, at: t0)
        store.record("psql", for: hostB, at: t0)

        XCTAssertEqual(store.history(for: hostA).entries.map(\.command), ["make deploy"])
        XCTAssertEqual(store.history(for: hostB).entries.map(\.command), ["psql"])
    }

    func testPurgingOneHostLeavesTheOthers() {
        let store = CommandHistoryStore(directoryURL: directory)
        store.record("make deploy", for: hostA, at: t0)
        store.record("psql", for: hostB, at: t0)

        store.purge(for: hostA)

        XCTAssertTrue(store.history(for: hostA).entries.isEmpty)
        XCTAssertEqual(store.history(for: hostB).entries.count, 1)
        XCTAssertTrue(CommandHistoryStore(directoryURL: directory)
            .history(for: hostA).entries.isEmpty)
    }

    func testPurgeAllEmptiesEveryHost() {
        let store = CommandHistoryStore(directoryURL: directory)
        store.record("make deploy", for: hostA, at: t0)
        store.record("psql", for: hostB, at: t0)

        store.purgeAll()

        XCTAssertTrue(store.history(for: hostA).entries.isEmpty)
        XCTAssertTrue(store.history(for: hostB).entries.isEmpty)
    }

    func testTheLeadingSpaceRuleSurvivesTheStore() {
        let store = CommandHistoryStore(directoryURL: directory)
        store.record(" mysql -pSECRET", for: hostA, at: t0)
        XCTAssertTrue(CommandHistoryStore(directoryURL: directory)
            .history(for: hostA).entries.isEmpty)
    }

    func testACorruptFileReadsAsEmptyRatherThanCrashing() throws {
        try Data("not json".utf8).write(
            to: directory.appendingPathComponent("history-\(hostA.uuidString).json"))
        XCTAssertTrue(CommandHistoryStore(directoryURL: directory)
            .history(for: hostA).entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CommandHistoryStoreTests`
Expected: FAIL — `cannot find 'CommandHistoryStore' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Per-host command history on disk, one JSON file per host.
///
/// Shaped like `HostStore`, with one difference: the files are written with
/// `FileProtectionType.complete`, so they are unreadable while the device is
/// locked. A host list is not sensitive; a command history is — it carries
/// internal hostnames, paths, and now and then a secret someone typed as an
/// argument. Only extracted commands are ever written here; screen text is not.
public final class CommandHistoryStore {
    private let directory: URL
    private var cache: [UUID: CommandHistory] = [:]

    /// - Parameter directoryURL: override the storage location (used by tests).
    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directory = directoryURL
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base
        }
    }

    public func history(for host: UUID) -> CommandHistory {
        if let cached = cache[host] { return cached }
        let loaded = (try? Data(contentsOf: url(for: host)))
            .flatMap { try? JSONDecoder().decode(CommandHistory.self, from: $0) }
            ?? CommandHistory()
        cache[host] = loaded
        return loaded
    }

    public func record(_ command: String, for host: UUID, at date: Date = Date()) {
        var history = history(for: host)
        history.record(command, at: date)
        write(history, for: host)
    }

    public func purge(for host: UUID) {
        write(CommandHistory(), for: host)
    }

    public func purgeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("history-") {
            try? FileManager.default.removeItem(at: file)
        }
        cache.removeAll()
    }

    // MARK: - Private

    private func url(for host: UUID) -> URL {
        directory.appendingPathComponent("history-\(host.uuidString).json")
    }

    private func write(_ history: CommandHistory, for host: UUID) {
        cache[host] = history
        guard let data = try? JSONEncoder().encode(history) else { return }
        // .completeFileProtection is a no-op on macOS and Linux, and is what
        // keeps the file unreadable on a locked iPhone.
        try? data.write(to: url(for: host), options: [.atomic, .completeFileProtection])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CommandHistoryStoreTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SloopKit/Terminal/CommandHistoryStore.swift Tests/SloopKitTests/CommandHistoryStoreTests.swift
git commit -m "SloopKit: persist command history per host, protected at rest"
```

---

### Task 3: `CommandExtractor` and the tuning harness

This is where the feature's real risk lives. The code is small; the prompt is not, and the only way to get it right is to run it against real terminal text many times. That is what the harness is for, and why it comes before anything is wired to the terminal.

**Files:**
- Create: `App/Sloop/Intelligence/CommandExtractor.swift`
- Create: `App/Sloop/Intelligence/ExtractionHarnessView.swift`
- Modify: `App/Sloop/Views/TerminalSettingsView.swift` (a debug entry point, macOS only)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `CommandExtractor` with `static var isAvailable: Bool` and `func commands(in screenText: String) async -> [String]`. Tasks 4 and 6 consume both.

- [ ] **Step 1: Confirm the Foundation Models API before writing anything**

**Do not write against the shapes in this plan without checking them.** The framework is young and this plan is written from memory. Confirm, in Apple's current documentation:

- the entry point for availability (assumed: `SystemLanguageModel.default.availability`, with an `.available` case and an `.unavailable(reason)` case),
- how a session is created and prompted (assumed: `LanguageModelSession(instructions:)` then `try await session.respond(to:)`),
- the macro and API for structured output (assumed: `@Generable` on a struct, `@Guide` on its properties, and a `generating:` parameter on `respond`).

Write down what you find at the top of your report. If the real API differs, follow the real API and keep the design: text in, a typed list of commands out, availability checked before use.

- [ ] **Step 2: Write the extractor**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a region of terminal screen text into the commands that were run in it.
///
/// The model does the reading, which is the whole point: no prompt-boundary
/// parser, no alternate-screen detection, no heuristics for wrapped lines. A
/// `vim` screen yields no commands because the model recognises a `vim` screen,
/// not because we detected the alternate buffer.
///
/// Takes text and returns values — no UIKit, no SwiftUI, nothing iOS-only — so
/// it can be driven from the macOS app or the harness while the prompt is
/// being tuned.
struct CommandExtractor {

    /// Whether the on-device model can actually be used right now. False when
    /// the OS is too old, the hardware is below the Apple Intelligence bar, the
    /// user has it switched off, or the model is still downloading.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    func commands(in screenText: String) async -> [String] {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), Self.isAvailable {
            return await extract(from: screenText)
        }
        #endif
        return []
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    private func extract(from screenText: String) async -> [String] {
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let result = try await session.respond(
                to: screenText, generating: ExtractedCommands.self)
            return result.content.commands
        } catch {
            // A failed extraction must leave the history untouched rather than
            // guessing. Losing one screen's commands is invisible; inventing
            // them is not.
            return []
        }
    }

    @available(iOS 26, macOS 26, *)
    @Generable
    private struct ExtractedCommands {
        @Guide(description: "Shell commands that were run, in the order they appear. Empty if none.")
        let commands: [String]
    }
    #endif

    /// Tune this against real screens in the harness (`ExtractionHarnessView`)
    /// before trusting it. Extraction quality is the feature.
    static let instructions = """
        You are reading text captured from a terminal.

        Identify the shell commands the user ran. A command is what follows a \
        shell prompt on a line the user submitted — not the output it produced, \
        not the prompt itself, and not text belonging to a full-screen program.

        Rules:
        - Return the command only, without the prompt that preceded it.
        - Ignore output, banners, error messages, and progress lines.
        - If the screen shows a full-screen program (an editor, a pager, a \
          terminal multiplexer), there are no commands on it — return an empty list.
        - If nothing on the screen is a command, return an empty list. An empty \
          answer is correct far more often than a guess.
        - Do not invent, correct, complete, or tidy a command. Return exactly \
          the text that was run.
        """
}
```

- [ ] **Step 3: Build the harness**

A macOS-only screen: paste terminal text into a text editor, tap Extract, see what comes back. This is the loop the prompt gets tuned in — seconds per iteration, no device, no deploy, real text.

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if os(macOS)
import SwiftUI

/// A development surface for tuning the extraction prompt against real
/// terminal text. Not shipped to users — this is the fast loop the design
/// depends on: paste a screen, see the commands, change the prompt, repeat.
struct ExtractionHarnessView: View {
    @State private var screenText = ""
    @State private var extracted: [String] = []
    @State private var isRunning = false
    @State private var ranOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CommandExtractor.isAvailable
                 ? "On-device model available."
                 : "On-device model unavailable — check macOS 26 + Apple Intelligence.")
                .font(.footnote)
                .foregroundStyle(CommandExtractor.isAvailable ? .secondary : .red)

            Text("Paste terminal text").font(.headline)
            TextEditor(text: $screenText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .border(.quaternary)

            Button(isRunning ? "Extracting…" : "Extract") {
                Task {
                    isRunning = true
                    extracted = await CommandExtractor().commands(in: screenText)
                    isRunning = false
                    ranOnce = true
                }
            }
            .disabled(isRunning || screenText.isEmpty || !CommandExtractor.isAvailable)

            Text("Commands").font(.headline)
            if extracted.isEmpty {
                Text(ranOnce ? "None found." : "Nothing extracted yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(Array(extracted.enumerated()), id: \.offset) { _, command in
                    Text(command).font(.system(.body, design: .monospaced))
                }
                .frame(minHeight: 150)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 620)
    }
}
#endif
```

Add a way in: in `TerminalSettingsView`, inside `#if os(macOS)` **and** `#if DEBUG`, add a `Section("Development")` with a button presenting `ExtractionHarnessView` in a sheet. It must not appear in a release build or on iOS.

- [ ] **Step 4: Tune the prompt against real screens**

This step is the point of the task. Do not skip it and do not treat the prompt above as finished.

Collect at least six varied screens by copying real terminal text — a plain shell session with several commands; a session with long, wrapped commands; a `git` session with multi-line output; a `vim` or `less` screen; a screen showing only output and no prompt; a screen with a password prompt visible (`sudo` asking) to confirm nothing is invented for it.

For each, run the harness and record what came back. Iterate on `CommandExtractor.instructions` until:

- commands come back without their prompts,
- full-screen program output yields an empty list,
- output-only screens yield an empty list,
- nothing is invented, completed, or corrected.

Put the before/after in your report, with the screens you used. **The tuned prompt is the deliverable of this task**, not the code around it.

- [ ] **Step 5: Verify it builds for both platforms**

```bash
xcodegen generate
xcodebuild -project Sloop.xcodeproj -scheme Sloop_macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
xcodebuild -project Sloop.xcodeproj -scheme Sloop_iOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
swift test
```

Expected: both `BUILD SUCCEEDED`; `swift test` unchanged (this task adds no SloopKit code). Confirm a `SwiftCompile` line for `CommandExtractor.swift` in the build log rather than trusting the banner — new files can be silently absent from a stale project.

- [ ] **Step 6: Commit**

```bash
git add App/Sloop/Intelligence/ App/Sloop/Views/TerminalSettingsView.swift
git commit -m "Intelligence: read commands off the screen, and a harness to tune it"
```

---

### Task 4: Capture — snapshot the screen on Return

**Files:**
- Modify: `App/Sloop/Views/TerminalController.swift`
- Create: `App/Sloop/Intelligence/CommandCapture.swift`

**Interfaces:**
- Consumes: `CommandExtractor` (Task 3), `CommandHistoryStore` (Task 2).
- Produces: `CommandCapture` with `init(hostID:store:extractor:)`, `noteReturnPressed(reading:)`, and `@Published private(set) var history: CommandHistory`. Tasks 5 and 6 consume it.

- [ ] **Step 1: Write the capture type**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SwiftTerm
import SloopKit

/// Watches one session for commands and files them into the history.
///
/// Snapshotting is a string copy on the input path; extraction is not. The
/// model call happens in a detached task so a slow extraction can never show
/// up as keyboard lag — the user pressing Return must never wait for it.
@MainActor
final class CommandCapture: ObservableObject {
    @Published private(set) var history: CommandHistory

    private let hostID: UUID
    private let store: CommandHistoryStore
    private let extractor: CommandExtractor
    /// Where the previous snapshot ended, so each one covers only new ground.
    private var lastSnapshotRow = 0

    init(hostID: UUID, store: CommandHistoryStore, extractor: CommandExtractor = CommandExtractor()) {
        self.hostID = hostID
        self.store = store
        self.extractor = extractor
        self.history = store.history(for: hostID)
    }

    /// Called when the user sends Return. Reads the screen written since the
    /// last snapshot and queues it for extraction.
    ///
    /// The screen, never the keystrokes: a password is not echoed, so it is
    /// not on the screen, so it cannot be captured. That property is why this
    /// reads `getText` rather than the bytes the user typed.
    func noteReturnPressed(reading terminal: Terminal) {
        guard CommandExtractor.isAvailable else { return }

        let (_, cursorRow) = terminal.getCursorLocation()
        let startRow = min(lastSnapshotRow, cursorRow)
        let text = terminal.getText(
            start: Position(col: 0, row: startRow),
            end: Position(col: terminal.cols - 1, row: cursorRow))
        lastSnapshotRow = cursorRow

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task { [extractor, hostID, store] in
            let commands = await extractor.commands(in: text)
            guard !commands.isEmpty else { return }
            await MainActor.run {
                for command in commands { store.record(command, for: hostID) }
                self.history = store.history(for: hostID)
            }
        }
    }

    func purge() {
        store.purge(for: hostID)
        history = store.history(for: hostID)
    }
}
```

If `Position` is not the initialiser SwiftTerm exposes for `getText(start:end:)`, use whatever its signature actually requires — check `Terminal.getText` in the SwiftTerm checkout and adjust. The shape (a start and an end coordinate) is what matters.

- [ ] **Step 2: Hook it into the send path**

In `TerminalController`, add a `let capture: CommandCapture` (constructed with the session's host ID and a shared `CommandHistoryStore`), and call it from the delegate method that already sees every byte the user sends.

In `send(source:data:)`, **before** the existing `armedModifiers` logic, add:

```swift
if data.contains(0x0d) {
    capture.noteReturnPressed(reading: source.getTerminal())
}
```

`0x0d` is Return. It goes first so that a Return arriving with an armed modifier is still captured, and the existing modifier handling is untouched.

- [ ] **Step 3: Verify it builds and the suite is unchanged**

```bash
xcodegen generate
xcodebuild -project Sloop.xcodeproj -scheme Sloop_iOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
swift test
```
Expected: `BUILD SUCCEEDED`; `swift test` unchanged.

- [ ] **Step 4: Verify capture works, on the Mac**

Run the macOS app, connect to a host, run four or five commands, and confirm they land in the history. The quickest window on it is the harness screen from Task 3 or a temporary `print` in `CommandCapture`; state in your report which you used and what you saw.

Then check the two properties that matter:
- **`sudo` something and type the password.** The password must not appear in the history. It is not echoed, so it is not on screen, so it cannot be captured — confirm that holds in practice.
- **Run a command with a leading space.** It must not be recorded.

- [ ] **Step 5: Commit**

```bash
git add App/Sloop/Intelligence/CommandCapture.swift App/Sloop/Views/TerminalController.swift
git commit -m "Terminal: build command history by reading the screen on Return"
```

---

### Task 5: The suggestion strip

**Files:**
- Create: `App/Sloop/Views/SuggestionStrip.swift`
- Modify: `App/Sloop/Views/TerminalPane.swift`

**Interfaces:**
- Consumes: `CommandCapture` (Task 4), `CommandHistory` (Task 1).
- Produces: `SuggestionStrip(suggestions:onTap:)` and `Suggestion` (`text`, `isRecalled`). Task 6 replaces where `suggestions` comes from.

- [ ] **Step 1: Write the strip**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if os(iOS)
import SwiftUI

/// One offered command. `isRecalled` is computed by checking the history, not
/// claimed by the model — see `SuggestionStrip` for why the distinction is
/// drawn in the UI at all.
struct Suggestion: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let isRecalled: Bool
}

/// Commands offered above the keyboard. Tapping inserts; the user still
/// presses Return.
///
/// Recalled and invented suggestions look different on purpose. A command out
/// of history carries the authority of "I ran this before"; a generated one is
/// the model's guess and deserves a read. Presenting them identically would
/// launder the second into the first, and the failure mode worth designing
/// against here is not a bad suggestion but an unexamined one.
struct SuggestionStrip: View {
    let suggestions: [Suggestion]
    let onTap: (Suggestion) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    Button { onTap(suggestion) } label: {
                        HStack(spacing: 5) {
                            // Numbered so the !1 !2 idiom works by eye.
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(suggestion.text)
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(1)
                            if !suggestion.isRecalled {
                                Image(systemName: "sparkle")
                                    .font(.caption2)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            suggestion.isRecalled
                                ? AnyShapeStyle(.quaternary)
                                : AnyShapeStyle(.tint.opacity(0.15)),
                            in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(suggestion.isRecalled
                        ? "\(suggestion.text), from history"
                        : "\(suggestion.text), suggested")
                    .accessibilityHint("Inserts the command. You still press Return to run it.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }
}
#endif
```

- [ ] **Step 2: Show it in `TerminalPane`**

Put the strip directly above the existing keyboard accessory, so it stacks with the smart-keys bar rather than replacing it. Populate it from `capture.history.ranked(matching: "", limit: 8)`, mapping each entry to `Suggestion(text:isRecalled: true)` — everything is recalled until Task 6 adds invention.

Tapping sends the command's bytes as if typed, **without** a trailing Return:

```swift
controller.send(ArraySlice(Array(suggestion.text.utf8)))
```

Show nothing when the list is empty, so the strip costs no rows before there is any history.

- [ ] **Step 3: Verify**

```bash
xcodegen generate
xcodebuild -project Sloop.xcodeproj -scheme Sloop_iOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
swift test
```
Expected: `BUILD SUCCEEDED`; suite unchanged.

Then in the Simulator: connect, run a few commands, confirm they appear in the strip, and confirm tapping one **inserts without running it** — the cursor should sit at the end of the inserted text with nothing executed until Return is pressed. That last check is the safety property; verify it explicitly rather than assuming.

- [ ] **Step 4: Commit**

```bash
git add App/Sloop/Views/SuggestionStrip.swift App/Sloop/Views/TerminalPane.swift
git commit -m "Terminal: offer commands above the keyboard, insert on tap"
```

---

### Task 6: Suggestion — let the model propose

**Files:**
- Create: `App/Sloop/Intelligence/CommandSuggester.swift`
- Modify: `App/Sloop/Intelligence/CommandCapture.swift`, `App/Sloop/Views/TerminalPane.swift`

**Interfaces:**
- Consumes: `CommandHistory`, `CommandExtractor.isAvailable`, `Suggestion`.
- Produces: `CommandSuggester.suggestions(screen:typed:history:limit:) async -> [Suggestion]`.

Until now every suggestion came out of history. This is where the model may propose a command the user has never run — the flag they cannot remember, the incantation they would otherwise go and look up. That is the point of the feature, and it is also what makes the recalled/invented distinction load-bearing rather than decorative.

- [ ] **Step 1: Write the suggester**

Mirror `CommandExtractor`'s shape: `#if canImport(FoundationModels)`, `@available(iOS 26, macOS 26, *)`, a `@Generable` result, an availability guard, and an empty array on failure.

Its prompt gets three things — the current screen, whatever the user has typed on the line so far, and `history.ranked(matching: typed, limit: 20)` as context. Instructions along these lines, to be tuned in the harness the same way Task 3's were:

```
Suggest the next shell command.

You are given the current terminal screen, what the user has typed so far,
and commands this user has run on this host before.

The history shows you their conventions — the tools they use, how they
spell things, their paths and host names. Follow those conventions.

Suggest a command they have run before when that is genuinely the most
useful next step. Otherwise suggest a new one: the command worth
suggesting is often the one they could not have recalled.

If the user has typed a prefix, every suggestion must start with it.
Return at most 5, best first. Return none rather than padding the list.
```

Tag the results by checking the store, not by asking the model:

```swift
let isRecalled = history.contains(text)
```

The model is not asked to be honest about its own novelty; the answer is computed from data we already hold.

- [ ] **Step 2: Wire it in**

`CommandCapture` gains a debounced `refreshSuggestions(screen:typed:)` that calls the suggester and publishes `[Suggestion]`. `TerminalPane` reads that instead of the raw frecency list from Task 5.

Debounce matters: this runs while someone is typing, and one model call per keystroke is both slow and pointless. Wait for a pause (~300ms) and cancel the in-flight task when a newer request arrives.

Keep the frecency list as what shows *before* the model has answered, so the strip is populated immediately and improves rather than appearing late.

- [ ] **Step 3: Tune, in the harness**

Extend the harness with a second pane: paste a screen, type a prefix, see the suggestions and which are marked invented. Iterate the instructions until suggestions are plausible, respect the typed prefix, follow the history's conventions, and the list stays short rather than padded.

Record before/after in your report, as in Task 3.

- [ ] **Step 4: Verify**

Build both schemes, run `swift test`, then in the Simulator confirm: suggestions appear and update as you type; invented ones are visibly distinct from recalled ones; a tap still only inserts.

- [ ] **Step 5: Commit**

```bash
git add App/Sloop/Intelligence/ App/Sloop/Views/TerminalPane.swift
git commit -m "Intelligence: suggest commands, including ones never run before"
```

---

### Task 7: Purge, and the roadmap

**Files:**
- Modify: `App/Sloop/Views/TerminalSettingsView.swift`, `Docs/ROADMAP.md`

- [ ] **Step 1: Add the purge affordance**

A `Section("Suggestions")` in `TerminalSettingsView` with:

- a line saying where suggestions come from and that they never leave the device — plain language, because "an on-device model reads my terminal" is a claim a user is entitled to understand;
- a destructive "Clear Command History" button, behind a confirmation, calling `CommandHistoryStore.purgeAll()`;
- when `CommandExtractor.isAvailable` is false, a line saying suggestions are unavailable on this device and why, so the absence reads as deliberate rather than broken.

- [ ] **Step 2: Update the roadmap**

Replace the open-question snippets bullet under `## Nice-to-have` with a done entry naming what shipped and what did not: on-device only, insert-never-execute, requires iOS 26 with Apple Intelligence, and that a mode for older devices is still outstanding. Point at the spec.

- [ ] **Step 3: Verify**

```bash
xcodegen generate
xcodebuild -project Sloop.xcodeproj -scheme Sloop_iOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
xcodebuild -project Sloop.xcodeproj -scheme Sloop_macOS -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
swift test
```
Expected: both succeed; suite green.

Confirm purge actually empties the strip, and that the unavailable-device copy appears when `CommandExtractor.isAvailable` is false (test by temporarily returning `false` from it, then revert).

- [ ] **Step 4: Commit**

```bash
git add App/Sloop/Views/TerminalSettingsView.swift Docs/ROADMAP.md
git commit -m "Settings: explain where suggestions come from, and let them be cleared"
```

---

## Outstanding after this plan

- **A tablet has not seen this.** The only iPad on hand is a 9th generation (A13), below the Apple Intelligence bar, so nothing here can run on it. The tablet is where the strip has the most room and the most to prove, and no judgement about how it feels there is available yet.
- **A mode for devices without the model** is deliberately not in this plan. Everything below iOS 26, and every device under the Apple Intelligence bar — including the current base iPad's A16 — gets no strip at all.
- **Suggestion quality is whatever the stock model gives.** No adapter, no fine-tuning. If quality is the limiting factor, that is a finding to act on with its own spec, and on evidence rather than in advance.
