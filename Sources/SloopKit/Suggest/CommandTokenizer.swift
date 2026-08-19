// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Splits a command line into words the way a shell does, so suggestions can
/// reason about `zpool` then `status` rather than about one long string.
///
/// Quotes matter: `git commit -m "fix the thing"` is four words, not seven, and
/// splitting on spaces alone would offer `the` as a plausible next word after
/// `fix`. This is not a shell parser — it knows nothing of expansion,
/// substitution or operators — it only needs to agree with a shell about where
/// one word ends and the next begins.
public enum CommandTokenizer {
    /// The words of a command line, in order.
    public static func tokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where quote != "'":
                // A backslash quotes the next character everywhere except
                // inside single quotes, where it is literal.
                escaped = true
            case "'", "\"":
                if quote == character {
                    quote = nil          // closing
                } else if quote == nil {
                    quote = character    // opening
                } else {
                    current.append(character)   // the other kind, inside this one
                }
            case " ", "\t" where quote == nil:
                if quote == nil {
                    if !current.isEmpty { tokens.append(current); current = "" }
                } else {
                    current.append(character)
                }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// The words already settled, and the word being typed.
    ///
    /// A line ending in a space has no partial word — the user is asking what
    /// comes *next*, which is the case a next-word model answers best.
    public static func context(_ line: String) -> (settled: [String], partial: String) {
        let tokens = tokens(line)
        guard let last = line.last, last != " ", last != "\t" else {
            return (tokens, "")
        }
        guard let partial = tokens.last else { return ([], "") }
        return (Array(tokens.dropLast()), partial)
    }
}
