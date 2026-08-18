// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// The commands a host has seen, and what to suggest from them.
///
/// Ranked a word at a time: given the words already typed, which word follows
/// them most often and most recently? Frecency still decides — how often,
/// weighted by how recently — but it is applied to the *next word* rather than
/// to whole command lines, because a whole-line score cannot know that `status`
/// follows `zpool` almost always while `destroy` followed it once, on a Tuesday.
/// Suggesting `zpool destroy` first is the kind of mistake that only has to
/// happen once.
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
    /// Ranked a word at a time, in context: of the commands that begin the way
    /// this line begins, which word comes next most often and most recently?
    /// Whole-line frecency — the first version — ranked `zpool destroy` above
    /// `zpool status` because it was typed once, recently, and nothing about a
    /// whole-line score knows that `status` is what follows `zpool` nearly
    /// every time. A next-word model does, and it is also the model that
    /// generalises: a command typed for the first time still gets a useful
    /// suggestion for its second word.
    ///
    /// Returns the settled words plus the proposed one, so the bar shows a
    /// command fragment that reads, and accepting builds the line up a word at
    /// a time.
    public func suggestions(for prefix: String, limit: Int = 3,
                            now: Date = Date()) -> [String] {
        let (settled, partial) = CommandTokenizer.context(prefix)
        guard !settled.isEmpty || !partial.isEmpty else { return [] }

        var scores: [String: Double] = [:]
        var suggestion: [String: [String]] = [:]

        for entry in entries.values {
            let words = CommandTokenizer.tokens(entry.command)
            guard words.count > settled.count,
                  Array(words.prefix(settled.count)) == settled else { continue }

            let candidate = words[settled.count]
            if candidate == partial {
                // The word is complete. Offer what follows it, so a finished
                // word doesn't blank the bar until a space is typed.
                if words.count > settled.count + 1 {
                    let next = words[settled.count + 1]
                    let key = "\(settled.count + 1)\u{0}\(next)"
                    scores[key, default: 0] += score(entry, now: now)
                    suggestion[key] = settled + [candidate, next]
                }
            } else if candidate.hasPrefix(partial) {
                let key = "\(settled.count)\u{0}\(candidate)"
                scores[key, default: 0] += score(entry, now: now)
                suggestion[key] = settled + [candidate]
            }
        }

        let typed = prefix.trimmingCharacters(in: .whitespaces)
        return scores
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { suggestion[$0.key]?.joined(separator: " ") }
            .filter { $0 != typed }
            .prefix(limit)
            .map { $0 }
    }

    /// The most recently recorded commands, newest first    /// The most recently recorded commands, newest first    /// The most recently recorded commands, newest first — what the shell's own
    /// up arrow is walking back through, as far as we know it.
    public func recent(limit: Int) -> [String] {
        entries.values
            .sorted { (order[$0.command] ?? 0) > (order[$1.command] ?? 0) }
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
