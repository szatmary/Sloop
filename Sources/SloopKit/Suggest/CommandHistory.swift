// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// The commands a host has seen, and what to suggest from them.
///
/// Ranked by frecency — how often a command is used, weighted by how recently —
/// which is what makes the list feel like it knows you rather than like a log.
/// `git status` typed forty times last month should lose to `git rebase -i`
/// typed twice this morning, and a plain frequency count gets that backwards.
///
/// Two sources feed it: the commands typed in Sloop, and the host's own shell
/// history, read once per connect. The second is what makes it useful on the
/// first day rather than the second week.
public struct CommandHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let command: String
        public var count: Int
        public var lastUsed: Date
    }

    private var entries: [String: Entry] = [:]

    /// Newest-first order among equally-scored entries, so a history imported
    /// in file order still ranks its most recent lines first.
    private var sequence: Int = 0
    private var order: [String: Int] = [:]

    public init() {}

    public var commands: [String] { Array(entries.keys) }
    public var isEmpty: Bool { entries.isEmpty }

    /// Record a command the user ran.
    public mutating func record(_ command: String, at date: Date = Date()) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        sequence += 1
        order[command] = sequence
        if var existing = entries[command] {
            existing.count += 1
            existing.lastUsed = max(existing.lastUsed, date)
            entries[command] = existing
        } else {
            entries[command] = Entry(command: command, count: 1, lastUsed: date)
        }
    }

    /// Seed from the host's shell history, oldest line first.
    ///
    /// Imported lines count once each: a line's presence in `~/.zsh_history`
    /// says it was run, not how often, and inventing a count would let the
    /// import outrank commands actually typed here.
    public mutating func importLines(_ lines: [String], at date: Date = Date()) {
        for line in lines {
            let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty, entries[command] == nil else {
                // Already known: keep what we have, since a locally-typed entry
                // carries a real count and a real timestamp.
                continue
            }
            sequence += 1
            order[command] = sequence
            entries[command] = Entry(command: command, count: 1, lastUsed: date)
        }
    }

    /// The best completions for what's typed so far, most likely first.
    ///
    /// Returns whole commands, not the remaining text: the caller decides
    /// whether to show them, and `completion(of:for:)` works out what to send.
    public func suggestions(for prefix: String, limit: Int = 3,
                            now: Date = Date()) -> [String] {
        let prefix = String(prefix.drop(while: { $0 == " " }))
        guard !prefix.isEmpty else { return [] }
        return entries.values
            .filter { $0.command.hasPrefix(prefix) && $0.command != prefix }
            .sorted {
                let left = score($0, now: now), right = score($1, now: now)
                if left != right { return left > right }
                return (order[$0.command] ?? 0) > (order[$1.command] ?? 0)
            }
            .prefix(limit)
            .map(\.command)
    }

    /// What still has to be typed to turn `prefix` into `suggestion`, or nil if
    /// the suggestion doesn't extend it.
    public static func completion(of suggestion: String, for prefix: String) -> String? {
        guard suggestion.hasPrefix(prefix), suggestion.count > prefix.count else { return nil }
        return String(suggestion.dropFirst(prefix.count))
    }

    /// Frecency: how often, damped, times how recently, decayed.
    ///
    /// Count is log-scaled and recency halves every three days. Both parts
    /// matter. With a linear count, `git status` run forty times last month
    /// still beat `git rebase -i main` run twice this morning — the number is
    /// large enough to outlive any gentle decay, and the suggestion bar then
    /// spends its life offering the command you have most thoroughly finished
    /// with. Logs flatten that: the fortieth use of a command is worth far less
    /// than the second, which is also true of how much it tells you.
    private func score(_ entry: Entry, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(entry.lastUsed)) / (24 * 3600)
        let uses = 1 + log2(Double(entry.count))
        return uses * pow(0.5, days / 3)
    }
}
