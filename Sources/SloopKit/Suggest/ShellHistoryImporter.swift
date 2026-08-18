// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Reads the host's own shell history, so suggestions are useful on the first
/// connection rather than the second week.
///
/// Runs **after** the terminal session is up, never alongside it. The import is
/// a second SSH channel, and opening it in parallel with the connection the
/// user asked for means two authentications racing on a host that may rate-limit
/// them, count them against MaxSessions, or prompt twice. The suggestion bar is
/// a convenience; it does not get to make the connection less reliable.
public enum ShellHistoryImporter {
    /// How many lines to take from each file. Enough to cover the commands
    /// someone actually reuses, small enough to stay a single quick read.
    public static let lineLimit = 500

    /// Every history file worth trying, in the order most likely to be the
    /// one in use. `HISTFILE` comes first because it is whatever the shell
    /// actually reads — including shells nobody thought of when this was
    /// written — and the rest cover the shells that don't export it, or
    /// haven't yet in a non-interactive exec channel.
    ///
    /// Saying nothing is a valid answer: a host with no history isn't an error,
    /// it's a host nobody has typed on yet.
    static let historyFiles = [
        "${HISTFILE:-}",                          // whatever this shell uses
        "$HOME/.zsh_history",                     // zsh
        "$HOME/.bash_history",                    // bash
        "$HOME/.local/share/fish/fish_history",   // fish
        "$HOME/.sh_history",                      // ksh
        "$HOME/.ash_history",                     // ash, busybox
        "$HOME/.history",                         // tcsh, csh
        "$HOME/.config/nushell/history.txt",      // nushell, plain-text mode
    ]

    public static var command: String {
        let files = historyFiles.map { "\"\($0)\"" }.joined(separator: " ")
        return "for f in \(files); do "
            + "[ -f \"$f\" ] && tail -n \(lineLimit) \"$f\"; done 2>/dev/null; true"
    }

    /// Turn the raw output into commands, oldest first.
    ///
    /// Each shell stores its history in its own way, and the metadata is never
    /// something anyone typed: zsh prefixes `: <started>:<elapsed>;`, fish
    /// writes a YAML-ish record where the command is on a `- cmd:` line and the
    /// rest describes it. Multi-line entries (a command continued with a
    /// trailing backslash) are left as the single lines they appear as —
    /// suggesting half a heredoc would be worse than not suggesting it.
    public static func commands(fromHistoryOutput output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap(stripMetadata)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                // Control characters mean this wasn't a command line — a stray
                // escape sequence, or a binary file that happened to be at the
                // path HISTFILE pointed to.
                return !line.unicodeScalars.contains { $0.value < 0x20 }
            }
    }

    private static func stripMetadata(_ line: Substring) -> String? {
        // fish: "- cmd: git status", followed by "  when: …" and sometimes
        // "  paths:" entries that belong to it.
        if line.hasPrefix("- cmd: ") {
            return String(line.dropFirst("- cmd: ".count))
        }
        if line.hasPrefix("  ") { return nil }

        guard line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") else {
            return String(line)
        }
        // `: 1700000000:0;git status` — only strip when what's between is the
        // timestamp pair, so a command that merely starts with ": " survives.
        let metadata = line[line.index(line.startIndex, offsetBy: 2)..<semicolon]
        let parts = metadata.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return String(line)
        }
        return String(line[line.index(after: semicolon)...])
    }
}
