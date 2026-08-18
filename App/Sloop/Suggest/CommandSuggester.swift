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

    /// Feed the bytes being sent to the host. Commands the user finishes are
    /// recorded, so the next session knows them.
    func observe(_ bytes: ArraySlice<UInt8>) {
        for command in tracker.consume(bytes) {
            history.record(command)
            persist()
        }
    }

    /// What we believe is on the command line right now.
    var typedLine: String { tracker.line }

    /// The best completions for the line as it stands, or nothing at all when
    /// the line isn't one we can trust.
    func suggestions(limit: Int = 3) -> [String] {
        guard tracker.isSuggestable else { return [] }
        return history.suggestions(for: tracker.line, limit: limit)
    }

    /// What still has to be typed to reach `suggestion`.
    func completion(for suggestion: String) -> String? {
        guard tracker.isSuggestable else { return nil }
        return CommandHistory.completion(of: suggestion, for: tracker.line)
    }

    /// Read the host's own shell history over the connection that is already
    /// open, once per session.
    func importHistory(over transport: Transport, report: @escaping (String) -> Void = { _ in }) {
        guard !hasImported else { return }
        hasImported = true
        guard let runner = transport as? SessionCommandRunner else { return }
        runner.runOnSession(ShellHistoryImporter.command) { [weak self] output in
            guard let self else { return }
            let commands = output.map(ShellHistoryImporter.commands(fromHistoryOutput:)) ?? []
            DispatchQueue.main.async {
                let before = self.history.commands.count
                self.history.importLines(commands)
                self.persist()
                let learned = self.history.commands.count - before
                // Said once, on the connection where it happened. The import is
                // invisible by design, and an invisible feature that quietly
                // does nothing — as this did on every Mosh host — looks exactly
                // like one that works.
                report(learned > 0
                       ? "[sloop] suggestions: learned \(learned) commands from this host's shell history\r\n"
                       : "[sloop] suggestions: no shell history found on this host — learning as you type\r\n")
            }
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
