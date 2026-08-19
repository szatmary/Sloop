// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit

/// One session's suggestions: what the user is typing, what this host has seen
/// before, and the bridge between them.
///
/// Exists only when suggestions are switched on. That is the whole enforcement
/// of the setting — with no suggester there is no tracker consuming keystrokes
/// and no history being written, so "off" means nothing is recorded rather than
/// nothing is shown.
final class CommandSuggester {
    private let hostID: UUID
    private let store: CommandHistoryStore
    private var tracker = CommandLineTracker()
    private var history: CommandHistory
    /// Set once per session: a host's history is worth reading at connect, not
    /// on every reconnect of a flaky link.
    private var hasImported = false

    init(hostID: UUID, store: CommandHistoryStore = CommandHistoryStore()) {
        self.hostID = hostID
        self.store = store
        self.history = store.history(for: hostID)
    }

    var isSuggestable: Bool { tracker.isSuggestable }

    /// Feed the bytes being sent to the host. Commands the user finishes are
    /// recorded, so the next session knows them.
    func observe(_ bytes: ArraySlice<UInt8>) {
        for command in tracker.consume(bytes) {
            history.record(command)
            persist()
        }
        fillInRecalledLine()
    }

    /// The up arrow put *something* on the line, and the shell won't tell us
    /// what. Our own history is the best available guess: it is the same list,
    /// in the same order, minus anything run outside Sloop. Filling it in is
    /// what lets suggestions keep working while someone walks back through
    /// history and then edits what they find — which is how a shell is
    /// actually used.
    private func fillInRecalledLine() {
        let depth = tracker.recallDepth
        guard depth > 0 else { return }
        let recent = history.recent(limit: depth)
        guard recent.count == depth, let recalled = recent.last else { return }
        tracker.setLine(recalled)
    }

    /// What we believe is on the command line right now.
    var typedLine: String { tracker.line }

    /// The best completions for the line as it stands, or nothing at all when
    /// the line isn't one we can trust.
    func suggestions(limit: Int = 3) -> [String] {
        // Length, never content: this feature's promise is that what you type
        // stays on the device and goes nowhere, and a debug log of command
        // lines is a file that walks off it — pulled to a Mac, pasted into a
        // bug report. The length and the flags say everything a diagnosis
        // needs.
        DeviceDiagnostics.log("suggestions: typed=\(tracker.line.count) chars "
                              + "suggestable=\(tracker.isSuggestable) known=\(history.commands.count)")
        guard tracker.isSuggestable else { return [] }
        return history.suggestions(for: tracker.line, limit: limit)
    }

    /// The keystrokes that make the line read exactly `suggestion`: kill what's
    /// there, then type the whole thing.
    ///
    /// Not "the part not yet typed", which was the first version. That is right
    /// only while our model of the line is right, and after a history recall it
    /// is a guess — a good one, but a guess. Clearing first makes acceptance
    /// correct even when the guess was wrong: ⌃U is what every shell binds to
    /// discard the line, so the result is the command the user tapped and
    /// nothing else, whatever was really on screen.
    func acceptance(of suggestion: String) -> [UInt8] {
        [0x15] + Array(suggestion.utf8)   // ⌃U, then the command
    }

    /// Read the host's own shell history over the connection that is already
    /// open, once per session.
    func importHistory(over transport: Transport, report: @escaping (String) -> Void = { _ in }) {
        guard !hasImported else { return }
        hasImported = true
        guard let runner = transport as? SessionCommandRunner else { return }
        runner.runOnSession(ShellHistoryImporter.command) { [weak self] output in
            self?.absorb(historyOutput: output, report: report)
        }
    }

    /// Take history that arrived by some other route — Mosh reads it on the
    /// bootstrap channel, because that connection is the only one it will ever
    /// have and it closes before the terminal opens.
    func absorb(historyOutput output: String?, report: @escaping (String) -> Void = { _ in }) {
        DeviceDiagnostics.log("suggestions: absorb history — \(output?.count ?? -1) bytes")
        guard !hasImported || output != nil else { return }
        hasImported = true
        let commands = output.map(ShellHistoryImporter.commands(fromHistoryOutput:)) ?? []
        DispatchQueue.main.async {
            let before = self.history.commands.count
            self.history.importLines(commands)
            self.persist()
            let learned = self.history.commands.count - before
            // Said once, on the connection where it happened. The import is
            // invisible by design, and an invisible feature that quietly does
            // nothing — as this did on every Mosh host — looks exactly like one
            // that works.
            report(learned > 0
                   ? "[sloop] suggestions: read \(learned) commands from this host's shell history\r\n"
                   : "[sloop] suggestions: no shell history on this host — building the list as you type\r\n")
        }
    }

    /// A Mosh session, a reconnect, anything that redrew the screen: the line
    /// we think is being typed may not be the line on it.
    func invalidateLine() {
        tracker.invalidate()
    }

    private func persist() {
        // Best-effort by design: a history that cannot be written is a
        // convenience lost, not a session harmed, and the alternative is
        // interrupting someone's shell to report a file error about a feature
        // they may not know exists.
        try? store.save(history, for: hostID)
    }
}
