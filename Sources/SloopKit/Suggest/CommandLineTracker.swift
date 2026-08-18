// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Rebuilds the command line the user is typing, from the bytes Sloop sends.
///
/// The remote shell owns the real line; this is a model of it, and models drift.
/// Anything that edits the line in a way we cannot follow — a tab completion the
/// host performs, an arrow key moving the cursor, a control sequence we don't
/// model — marks the line **uncertain**, and an uncertain line offers no
/// suggestions at all.
///
/// That asymmetry is deliberate. A missing suggestion costs a moment; a
/// suggestion computed from a line that isn't what's on screen offers to
/// complete a command the user isn't typing, and accepting it sends the wrong
/// text to a live shell.
public struct CommandLineTracker: Equatable, Sendable {
    /// What we believe is typed so far on the current line.
    public private(set) var line: String = ""

    /// Whether `line` can be trusted. Cleared by anything we can't model,
    /// restored when the line is finished or abandoned.
    public private(set) var isCertain: Bool = true

    public init() {}

    /// Whether the line is worth suggesting against: known-good, and long
    /// enough that a prefix means something.
    public var isSuggestable: Bool {
        isCertain && line.count >= 2 && !line.hasSuffix(" ")
    }

    /// Feed the bytes being sent to the host. Returns any command the user
    /// finished — usually none, one at a time, or several when a multi-line
    /// paste arrives at once.
    @discardableResult
    public mutating func consume(_ bytes: ArraySlice<UInt8>) -> [String] {
        var finished: [String] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            index = bytes.index(after: index)

            switch byte {
            case 0x0d, 0x0a:                     // return / newline — line is done
                if isCertain, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    finished.append(line)
                }
                reset()

            case 0x7f, 0x08:                     // backspace
                if !line.isEmpty { line.removeLast() }

            case 0x03, 0x04:                     // ⌃C, ⌃D — the line is abandoned
                reset()

            case 0x15:                           // ⌃U — kill the whole line
                line = ""
                isCertain = true

            case 0x17:                           // ⌃W — kill the word behind
                killWordBackwards()

            case 0x1b:                           // ESC — arrows, meta, anything
                // Skip the rest of the sequence: whatever it did, we didn't
                // follow it.
                index = bytes.endIndex
                isCertain = false

            case 0x20...0x7e:                    // printable ASCII
                line.append(Character(UnicodeScalar(byte)))

            default:
                // ⌃A, ⌃E, ⌃K, ⌃R and the rest all move or rewrite the line in
                // ways this doesn't track. Tab is here too: the *host* decides
                // what a completion expands to, and we never see it.
                isCertain = false
            }
        }
        return finished
    }

    /// The host redrew the screen in a way that invalidates our model — a
    /// reconnect, a resize that rewrapped the line, a full-screen program
    /// exiting. Cheaper to admit than to guess.
    public mutating func invalidate() {
        isCertain = false
    }

    /// Start a fresh line, trusted again.
    public mutating func reset() {
        line = ""
        isCertain = true
    }

    private mutating func killWordBackwards() {
        while line.last == " " { line.removeLast() }
        while let last = line.last, last != " " { line.removeLast() }
    }
}
