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

    /// How many of `line`'s leading characters the host has echoed back.
    private var echoedCount = 0

    /// Where the escape-sequence stripper in `observeOutput` left off.
    private var outputScan: OutputScan = .text

    private enum OutputScan {
        case text
        case afterEscape
        case csi
        case osc
    }

    /// Replace the line with what the caller believes the shell just recalled.
    ///
    /// The text must come from the caller's own command history — that is the
    /// only source this can accept, because it arrives already counted as
    /// echoed. History holds nothing but lines the host echoed back, so a
    /// recalled line cannot be a secret; the alternative, waiting for an echo
    /// the host has no reason to send for a line already on screen, would stop
    /// recording anything after the first up-arrow.
    public mutating func setLine(_ line: String) {
        self.line = line
        echoedCount = line.count
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
                if isCertain, isRecordable {
                    finished.append(line)
                }
                reset()

            case 0x7f, 0x08:                     // backspace
                if !line.isEmpty {
                    line.removeLast()
                    echoedCount = min(echoedCount, line.count)
                }

            case 0x03, 0x04:                     // ⌃C, ⌃D — the line is abandoned
                reset()

            case 0x15:                           // ⌃U — kill the whole line
                line = ""
                echoedCount = 0
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
                    echoedCount = 0
                case .down:
                    recallDepth = max(0, recallDepth - 1)
                    line = ""
                    echoedCount = 0
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

    /// Feed the bytes arriving *from* the host, so the tracker can see which
    /// of them are the terminal echoing what was typed.
    ///
    /// This is the whole password defence. Nothing here knows what a password
    /// prompt looks like — `sudo`, `su`, `ssh`, `mysql -p`, `passwd`, `gpg`,
    /// `read -s` and every prompt not yet invented differ in wording and share
    /// exactly one property: they turn the terminal's echo off, so what the
    /// user types does not come back. A line the host never echoed is a line
    /// typed into an echo-off prompt, and it is not remembered.
    ///
    /// Escape sequences are stripped rather than matched: zsh's syntax
    /// highlighting wraps every word in colour codes, and the characters
    /// inside them are still the echo. The stripper keeps its state between
    /// calls because host output arrives in whatever chunks the network hands
    /// over, and a sequence can be split across two of them.
    public mutating func observeOutput(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            switch outputScan {
            case .text:
                if byte == 0x1b { outputScan = .afterEscape } else { confirmEcho(of: byte) }
            case .afterEscape:
                switch byte {
                case 0x5b: outputScan = .csi          // '[' — control sequence
                case 0x5d: outputScan = .osc          // ']' — operating system command
                default:   outputScan = .text         // a two-byte sequence, now finished
                }
            case .csi:
                if (0x40...0x7e).contains(byte) { outputScan = .text }
            case .osc:
                // BEL ends it. So does ST (`ESC \`) — the ESC puts us back in
                // `.afterEscape`, which consumes the backslash as a two-byte
                // sequence and lands in `.text` either way.
                if byte == 0x07 { outputScan = .text }
                if byte == 0x1b { outputScan = .afterEscape }
            }
        }
    }

    /// Match one byte of host output against the next character still waiting
    /// to be echoed.
    ///
    /// In order, and never ahead of the typing: only output that arrives
    /// *after* a character was typed can echo it. Matching anywhere in the
    /// output would let the prompt vouch for what follows it — "Password: "
    /// alone covers most of the letters in `password`.
    private mutating func confirmEcho(of byte: UInt8) {
        let typed = line.utf8
        guard echoedCount < typed.count else { return }
        let next = typed.index(typed.startIndex, offsetBy: echoedCount)
        if typed[next] == byte { echoedCount += 1 }
    }

    /// Whether a finished line may be remembered.
    private var isRecordable: Bool {
        // The shell's own convention, and the spec's: a leading space means
        // "run this but don't remember it".
        guard line.first != " " else { return false }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        // Every character came back from the host, so this was not typed at a
        // prompt with echo off.
        return echoedCount >= line.count
    }

    /// The host redrew the screen in a way that invalidates our model — a
    /// reconnect, a resize that rewrapped the line, a full-screen program
    /// exiting. Cheaper to admit than to guess.
    public mutating func invalidate() {
        isCertain = false
    }

    /// Start a fresh line, trusted again.
    ///
    /// `outputScan` deliberately survives: it describes where the *output*
    /// parser is, which has nothing to do with which line is being typed, and
    /// resetting it mid-sequence would let the tail of an escape sequence be
    /// read as echo.
    public mutating func reset() {
        line = ""
        echoedCount = 0
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
        echoedCount = min(echoedCount, line.count)
    }
}
