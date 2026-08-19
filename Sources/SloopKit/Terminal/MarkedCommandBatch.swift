// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Several commands run in one shell invocation, and their outputs split back
/// apart afterwards.
///
/// One connection is sometimes all there is. A Mosh session's SSH connection
/// exists only long enough to start `mosh-server` and is gone before the
/// terminal opens, so everything anyone wants to ask that host has to be asked
/// on that single exec — or not at all. Rather than let each such question
/// invent its own way of tacking itself on (the shell-history import did, with
/// a marker constant of its own living in the Mosh module), they all ride this.
///
/// The markers are echoed by the script itself, so they appear on stdout
/// between one command's output and the next. A command whose *output* contains
/// the marker string would confuse the split; the marker is shaped to make that
/// a thing nobody does by accident.
public enum MarkedCommandBatch {
    /// What the script echoes before command `index`.
    static func marker(_ index: Int) -> String { "@@sloop-cmd-\(index)@@" }

    /// `lead`, then each command, each preceded by its marker.
    ///
    /// With no commands the lead is returned untouched — a caller that has
    /// nothing to ask runs exactly what it would have run without this type,
    /// which is what keeps "read nothing from a host that didn't ask" honest.
    public static func script(lead: String, commands: [String]) -> String {
        guard !commands.isEmpty else { return lead }
        let parts = commands.enumerated().map { "echo \(marker($0.offset)); \($0.element)" }
        return ([lead] + parts).joined(separator: "; ")
    }

    /// The lead's output, and one entry per command.
    ///
    /// An entry is `nil` when that command's marker never printed — the batch
    /// stopped early, or this output came from a script that never carried the
    /// command at all. It is `""` when the command ran and printed nothing,
    /// which is a real answer and a different one.
    public static func split(_ output: String,
                             count: Int) -> (lead: String, outputs: [String?]) {
        var outputs = [String?](repeating: nil, count: count)
        guard count > 0, let first = output.range(of: marker(0)) else {
            return (output, outputs)
        }
        let lead = trimmed(output[..<first.lowerBound])

        var start = first.upperBound
        for index in 0..<count {
            let next = index + 1 < count
                ? output.range(of: marker(index + 1), range: start..<output.endIndex)
                : nil
            // Everything up to the next marker, or — for the last command, and
            // for one cut off mid-run — the rest of the output.
            outputs[index] = trimmed(output[start..<(next?.lowerBound ?? output.endIndex)])
            guard let next else { break }
            start = next.upperBound
        }
        return (lead, outputs)
    }

    /// The newlines around a section are the script's punctuation, not the
    /// command's output: `echo <marker>` ends a line, and the command's own
    /// output ends one too.
    private static func trimmed(_ section: Substring) -> String {
        String(section).trimmingCharacters(in: .newlines)
    }
}
