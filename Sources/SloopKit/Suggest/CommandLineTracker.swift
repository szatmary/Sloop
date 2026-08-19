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

    /// How far back through the shell's history the user has walked with the
    /// up arrow, minus any downs. Zero means they're typing a fresh line.
    ///
    /// The shell owns its history and we never see what a recall put on the
    /// line — but it is almost always the same command *we* recorded last, so
    /// the caller can fill the line in from its own history. Wrong occasionally
    /// (commands run outside Sloop, a ⌃R search); harmless when wrong, because
    /// accepting a suggestion clears the line first rather than appending to
    /// whatever is really there.
    public private(set) var recallDepth: Int = 0

    /// Replace the line with what the caller believes the shell just recalled.
    public mutating func setLine(_ line: String) {
        self.line = line
        isCertain = true
    }

    /// Whether the line is worth suggesting against: known-good, and not empty.
    ///
    /// One character is enough. It was two, on the theory that a single letter
    /// is too vague to rank — but the ranking is what decides that, and `z`
    /// narrowing to `zpool` on a host where that is the only `z` command is
    /// precisely the moment a suggestion saves the most typing.
    ///
    /// A trailing space counts too, and used not to: "what comes after
    /// `zpool `" is the question a next-word model answers best.
    public var isSuggestable: Bool {
        isCertain && !line.isEmpty
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
                // Up and down are history recall, and the caller can fill in
                // what they landed on. Every other sequence moves the cursor or
                // edits the line somewhere we aren't watching.
                switch escapeSequence(bytes, from: &index) {
                case .up:
                    recallDepth += 1
                    line = ""
                case .down:
                    recallDepth = max(0, recallDepth - 1)
                    line = ""
                case .reply:
                    break   // the terminal answering the host, not a keystroke
                case .other:
                    loseCertainty()
                }

            case 0x20...0x7e:                    // printable ASCII
                line.append(Character(UnicodeScalar(byte)))

            default:
                // ⌃A, ⌃E, ⌃K, ⌃R and the rest all move or rewrite the line in
                // ways this doesn't track. Tab is here too: the *host* decides
                // what a completion expands to, and we never see it.
                loseCertainty()
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
        recallDepth = 0
    }

    private enum EscapeSequence {
        /// History recall — the caller can fill the line in from its own copy.
        case up, down
        /// The terminal answering a question the host asked it: cursor
        /// position, device attributes, focus. Not a keystroke, and not
        /// something that changes the line.
        case reply
        /// A key that moves or edits the line somewhere we aren't watching.
        case other
    }

    /// Consume the rest of an escape sequence and say what kind it was.
    ///
    /// The distinction that matters is keystroke versus reply. A terminal
    /// answers the host constantly — `ESC[…R` for cursor position, `ESC[?…c`
    /// for device attributes, `ESC[I`/`ESC[O` when focus moves — and those
    /// answers leave through the same channel as typing. Treating them as
    /// unmodelled keys meant the suggestion bar appeared and then vanished a
    /// moment later, every time the shell asked the terminal a question.
    ///
    /// Arrows arrive as `ESC [ A` or, in application-cursor mode, `ESC O A`;
    /// readline puts the terminal in the second mode, so both spellings count.
    private func escapeSequence(_ bytes: ArraySlice<UInt8>,
                                from index: inout ArraySlice<UInt8>.Index) -> EscapeSequence {
        guard index < bytes.endIndex else { return .other }
        let introducer = bytes[index]
        index = bytes.index(after: index)

        guard introducer == 0x5b || introducer == 0x4f else {   // '[' or 'O'
            // OSC and the rest: skip to the end and assume the worst.
            index = bytes.endIndex
            return .other
        }

        // Parameters and intermediates, then a final byte in 0x40…0x7e.
        var final: UInt8?
        while index < bytes.endIndex {
            let byte = bytes[index]
            index = bytes.index(after: index)
            if (0x40...0x7e).contains(byte) { final = byte; break }
        }
        guard let final else { return .other }

        switch final {
        case 0x41: return .up                       // A
        case 0x42: return .down                     // B
        case 0x52, 0x63, 0x6e, 0x74, 0x49, 0x4f:    // R, c, n, t, I, O
            return .reply
        default:
            return .other
        }
    }

    /// Stop trusting the line — unless there is no line yet.
    ///
    /// Uncertainty is only ever *about* accumulated text: with an empty line
    /// there is nothing to be wrong about, and a keystroke we can't model has
    /// nothing to corrupt. Without this exception the feature never worked at
    /// all, because a terminal answers the host's queries — device attributes,
    /// cursor position — through the very same channel as typing, and those
    /// replies are escape sequences. Every session opened with a handful of
    /// them, so the line was written off as untrustworthy before the user had
    /// touched a key, and stayed that way until the first Enter.
    private mutating func loseCertainty() {
        isCertain = line.isEmpty
    }

    private mutating func killWordBackwards() {
        while line.last == " " { line.removeLast() }
        while let last = line.last, last != " " { line.removeLast() }
    }
}
