// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// One key's position and size within a resolved layout, in points.
///
/// Plain `Double`s rather than `CGRect`/`CGFloat`: `KeyboardLayout` has no
/// CoreGraphics dependency today (only Foundation, so it builds and
/// unit-tests on any platform — see the package's own doc comment), and a
/// frame type shouldn't be the thing that changes that.
public struct KeyFrame: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A resolved software-keyboard layout: which keys, in which rows, how tall.
///
/// The layout varies by device because the constraint does. An iPad in
/// landscape has width to spare, so symbols get a row of their own and nothing
/// hides behind a gesture. A phone does not, so those same symbols ride on a
/// drag-up from the digit row — fewer rows, same reachable characters. That
/// equivalence is not a convention to be remembered; it is enforced by
/// `KeyboardLayoutTests.testPhoneAndPadReachTheSameCharacters`.
public struct KeyboardLayout: Equatable, Sendable {
    public let rows: [[KeyCap]]

    /// How many *trailing* caps in each row form the number pad, which is laid
    /// out flush right like the one on a full-size physical keyboard. Empty, or
    /// all zeroes, where the screen has no width to spare for it.
    ///
    /// Kept as a count per row rather than a separate array of rows so a caller
    /// building key views can still walk `rows` alone, in one order, and zip it
    /// against `frames(...)` — the arrangement that keeps views and frames from
    /// drifting apart.
    public let keypadColumns: [Int]
    /// Height of one key row, in points.
    ///
    /// NOTE: these values are unmeasured placeholders (see the Row height
    /// constants below). The task that derives them from real device metrics
    /// is blocked on hardware; only the *relationships* between contexts
    /// (pad shorter than phone portrait; phone landscape shorter than phone
    /// portrait) are load-bearing today.
    public let rowHeight: Double

    init(rows: [[KeyCap]], keypadColumns: [Int] = [], rowHeight: Double) {
        self.rows = rows
        self.keypadColumns = keypadColumns.isEmpty
            ? Array(repeating: 0, count: rows.count)
            : keypadColumns
        self.rowHeight = rowHeight
    }

    /// What a layout varies on.
    ///
    /// Deliberately just these two: `resolve(for:)` branches only on `idiom`
    /// and `orientation`. A `width` was carried here too until it was
    /// removed as dead — nothing ever read it, and the real width a screen
    /// has to lay keys out in is passed separately, per call, to
    /// `frames(width:padding:spacing:)`.
    public struct Context: Equatable, Sendable, CustomStringConvertible {
        public enum Idiom: Equatable, Sendable { case phone, pad }
        public enum Orientation: Equatable, Sendable { case portrait, landscape }

        public let idiom: Idiom
        public let orientation: Orientation

        public init(idiom: Idiom, orientation: Orientation) {
            self.idiom = idiom
            self.orientation = orientation
        }

        public var description: String { "\(idiom)/\(orientation)" }
    }

    /// The symbols a shell needs constantly and a prose keyboard buries.
    /// On iPad these are a row; on iPhone they become drag-up secondaries.
    private static let symbols: [Character] =
        ["~", "`", "|", "\\", "/", "[", "]", "{", "}", "<",
         ">", "-", "_", "=", "+", ";", ":", "'", "*"]

    public static func resolve(for context: Context) -> KeyboardLayout {
        switch context.idiom {
        case .pad:   return pad(context)
        case .phone: return phone(context)
        }
    }

    // MARK: Frames

    /// Slots a row's fixed-width caps claim, in key units.
    private func fixedSlots(in row: [KeyCap]) -> Double {
        row.reduce(0.0) { total, cap in
            switch cap.width {
            case .unit:            return total + 1
            case .wide(let scale): return total + scale
            case .flexible:        return total
            }
        }
    }

    /// Each row's main block — everything that isn't the number pad.
    private var mainBlocks: [[KeyCap]] {
        zip(rows, keypadColumns).map { row, columns in Array(row.dropLast(columns)) }
    }

    /// The largest key unit a row can use without overflowing.
    private func maximumUnit(in row: [KeyCap], content: Double, spacing: Double) -> Double {
        let gaps = spacing * Double(max(row.count - 1, 0))
        // A flexible cap is reserved at two units when sizing, so a row with a
        // space bar can't claim a unit the letter rows are unable to match.
        let slots = fixedSlots(in: row) + (row.contains { $0.width == .flexible } ? 2 : 0)
        return slots > 0 ? (content - gaps) / slots : content
    }

    /// The unit every letter is drawn at: whatever the tightest *letter* row
    /// can afford.
    ///
    /// Letter rows only. The iPad's symbol row carries about twenty keys, and
    /// sizing the alphabet to fit that would halve it — the goal is letters
    /// that match each other, not a keyboard shrunk to its densest row. A row
    /// too crowded for this unit gets its own smaller one instead (see
    /// `frames`), which is what the symbol row has always effectively used.
    private func letterUnit(content: Double, spacing: Double, keypadUnit: Double) -> Double {
        // Main blocks only: the number pad lives in the slack the letter rows
        // leave, so its columns must not drag the letter unit down. But the
        // width it occupies does reduce what's left for them, which is what
        // `keypadUnit` accounts for.
        //
        // Alphabetic, not merely "a character key": the symbol row is nothing
        // but character keys, and letting it qualify is what made the alphabet
        // shrink to fit twenty symbols.
        var smallest: Double?
        for (row, columns) in zip(rows, keypadColumns) {
            let main = Array(row.dropLast(columns))
            let carriesLetters = main.contains { cap in
                if case .character(let character) = cap.primary {
                    return cap.width == .unit && character.isLetter
                }
                return false
            }
            guard carriesLetters else { continue }
            let region = regionForMainBlock(row: row, columns: columns, content: content,
                                            spacing: spacing, keypadUnit: keypadUnit)
            let unit = maximumUnit(in: main, content: region, spacing: spacing)
            smallest = min(smallest ?? unit, unit)
        }
        return smallest ?? content
    }

    /// The width a row's main block has to itself, once the number pad beside
    /// it has taken its share.
    private func regionForMainBlock(row: [KeyCap], columns: Int, content: Double,
                                    spacing: Double, keypadUnit: Double) -> Double {
        guard columns > 0, keypadUnit > 0 else { return content }
        let pad = Array(row.suffix(columns))
        let keypadWidth = keypadUnit * fixedSlots(in: pad) + spacing * Double(pad.count - 1)
        return content - keypadWidth - spacing
    }

    /// The number pad is drawn at the letter unit, so its keys match the
    /// alphabet's and its columns line up down the keyboard.
    ///
    /// It cannot be sized from "whatever space is left over", which was the
    /// first attempt: the symbol row and the bottom row already fill the width,
    /// so the leftover is nothing and the pad collapsed to zero. A pad is a
    /// column every row makes room for, and the cost is that letters get
    /// smaller — which is the honest trade, and visible in the reference widths
    /// in `KeyboardLayoutTests`.

    /// One frame per cap, across all rows, in the same row-major order the
    /// caller built its key views in — so zipping `frames(...)` against those
    /// views lines them up positionally, with no index of its own to drift
    /// out of sync.
    ///
    /// Grid math, not a real layout engine. Letters are all drawn at one unit
    /// width — whatever the tightest letter row can afford — so a letter is the
    /// same size in every row. Dividing each row's width by its own key count
    /// instead, which this used to do, made the 9-key home row wider than the
    /// 10-key top row, and keys that change size between rows shift under the
    /// thumbs while typing.
    ///
    /// A row too crowded for that unit (the iPad's symbol row, around twenty
    /// keys) uses the largest unit that fits it instead, rather than dragging
    /// the whole alphabet down to its size.
    /// A row that then doesn't fill the width is centred, the way every phone
    /// keyboard lays out its home row. Rows containing the space bar are the
    /// exception: `.flexible` absorbs the slack, so those still run edge to
    /// edge — reserved at two units minimum so space stays a real target.
    ///
    /// This lives here (pure, platform-agnostic) rather than in
    /// `CompactKeyboardView` (UIKit, unreachable from a package test)
    /// specifically so `KeyboardLayoutTests` can check it against
    /// hand-computed values instead of a reviewer having to hand-trace
    /// `layoutSubviews`.
    public func frames(width: Double, padding: Double, spacing: Double) -> [KeyFrame] {
        let content = width - padding * 2
        // Letter and pad widths depend on each other: the pad is drawn at the
        // letter unit, and the letters have less room because of it. Size them
        // as though there were no pad, then again against the pad that width
        // implies. The second pass only shrinks, and the result is stable —
        // sizing the pad from the *first* pass keeps the region a touch
        // conservative rather than oscillating.
        let withoutPad = letterUnit(content: content, spacing: spacing, keypadUnit: 0)
        let letters = letterUnit(content: content, spacing: spacing, keypadUnit: withoutPad)
        let keypad = letters

        var result: [KeyFrame] = []
        var y = padding
        for (row, columns) in zip(rows, keypadColumns) {
            let main = Array(row.dropLast(columns))
            let pad = Array(row.suffix(columns))

            let keypadWidth = pad.isEmpty
                ? 0
                : keypad * fixedSlots(in: pad) + spacing * Double(pad.count - 1)
            let region = regionForMainBlock(row: row, columns: columns, content: content,
                                            spacing: spacing, keypadUnit: keypad)

            // The letter unit everywhere it fits; a row too crowded for it —
            // the iPad's symbol row — falls back to the largest unit that does.
            let unit = min(letters, maximumUnit(in: main, content: region, spacing: spacing))
            let gaps = spacing * Double(max(main.count - 1, 0))
            let fixed = fixedSlots(in: main) * unit
            let flexibleCount = Double(main.filter { $0.width == .flexible }.count)
            // Whatever a row's fixed keys don't use goes to its flexible cap,
            // never below two units.
            let flexibleWidth = flexibleCount > 0
                ? max(unit * 2, (region - gaps - fixed) / flexibleCount)
                : 0

            let used = fixed + flexibleWidth * flexibleCount + gaps
            var x = padding + max(0, (region - used) / 2)
            for cap in main {
                let capWidth: Double
                switch cap.width {
                case .unit:            capWidth = unit
                case .wide(let scale): capWidth = unit * scale
                case .flexible:        capWidth = flexibleWidth
                }
                result.append(KeyFrame(x: x, y: y, width: capWidth, height: rowHeight - spacing))
                x += capWidth + spacing
            }

            // Flush right, so the pad's own columns align regardless of what
            // the main block beside them is doing.
            x = padding + content - keypadWidth
            for cap in pad {
                let capWidth = keypad * fixedSlots(in: [cap])
                result.append(KeyFrame(x: x, y: y, width: capWidth, height: rowHeight - spacing))
                x += capWidth + spacing
            }
            y += rowHeight
        }
        return result
    }

    // MARK: iPad — five rows, symbols visible

    private static func pad(_ context: Context) -> KeyboardLayout {
        // iPad has the width to spare, so the always-visible symbol row also
        // carries paging and delete — `.key` values, not `.character`, so
        // they sit outside the character-parity invariant, but they still
        // need a home somewhere or they simply vanish in compact mode (see
        // `KeyboardChrome`'s doc comment for why that matters: this keyboard
        // replaces `KeyboardAccessoryBar`, which carries all five).
        let symbolRow = symbols.map { KeyCap.character($0) } + [KeyCap.character("\"")]
            + [.key(.home), .key(.end), .key(.pageUp), .key(.pageDown), .key(.delete)]

        // A number pad down the right, in the arrangement fingers already know
        // from a full-size keyboard — 789 / 456 / 123 / 0, with the operators
        // beside them. It costs nothing in key size: once every letter is drawn
        // at the same width, an iPad's letter rows leave roughly a third of the
        // screen empty, and this is what goes there.
        //
        // Digits appear twice on this keyboard, in the pad and on the number
        // row. That's the point of a number pad, and it's why the duplicate
        // check in the tests looks at the main block only.
        let keypadRows: [[KeyCap]] = [
            [.character("/"), .character("*"), .character("-")],
            [.character("7"), .character("8"), .character("9")],
            [.character("4"), .character("5"), .character("6")],
            [.character("1"), .character("2"), .character("3")],
            [.character("0"), .character("."), .key(.return)],
        ]

        let mainRows: [[KeyCap]] = [
            symbolRow,
            [.key(.escape)]
                + "1234567890".map { KeyCap.character($0) }
                + [.key(.backspace, width: .wide(1.5), repeats: true)],
            [.key(.tab)]
                + "qwertyuiop".map { KeyCap.character($0) }
                + [.key(.up, repeats: true)],
            [.modifier(.control)]
                + "asdfghjkl".map { KeyCap.character($0) }
                + [.key(.return, width: .wide(1.5)), .key(.down, repeats: true)],
            [.modifier(.option), .modifier(.shift)]
                + "zxcvbnm".map { KeyCap.character($0) }
                + [.character(","), .character("."),
                   .character(" ", width: .flexible),
                   .key(.left, repeats: true), .key(.right, repeats: true),
                   .command(.dismissKeyboard),
                   // Last, and alone: the same reasoning
                   // `KeyboardAccessoryBar` states for its own ✕ — closing
                   // a tab drops a live SSH session, so it belongs where a
                   // mis-tap while reaching for space/arrows/dismiss can't
                   // reach it.
                   .command(.closeTab)],
        ]

        return KeyboardLayout(
            rows: zip(mainRows, keypadRows).map { $0 + $1 },
            keypadColumns: keypadRows.map(\.count),
            // iPad keys are wide, so they can be short without becoming hard
            // to hit — which is the whole point, since height is what a
            // terminal wants back.
            rowHeight: context.orientation == .landscape ? 38 : 40)
    }

    // MARK: iPhone — four rows, symbols on drag

    private static func phone(_ context: Context) -> KeyboardLayout {
        // Convention-led pairings: shift-row order for the digits, and the
        // bracket/quote partners where one exists.
        let digits: [KeyCap] = [
            .character("1", secondary: .character("~")),
            .character("2", secondary: .character("`")),
            .character("3", secondary: .character("|")),
            .character("4", secondary: .character("\\")),
            .character("5", secondary: .character("/")),
            .character("6", secondary: .character("[")),
            .character("7", secondary: .character("]")),
            .character("8", secondary: .character("{")),
            .character("9", secondary: .character("}")),
            .character("0", secondary: .character("<")),
        ]
        let homeRow: [KeyCap] = [
            .character("a", secondary: .character(">")),
            .character("s", secondary: .character("-")),
            .character("d", secondary: .character("_")),
            .character("f", secondary: .character("=")),
            .character("g", secondary: .character("+")),
            .character("h", secondary: .character(";")),
            .character("j", secondary: .character(":")),
            .character("k", secondary: .character("'")),
            .character("l", secondary: .character("\"")),
        ]
        // `,` and `.` ride as secondaries on `n`/`m`, mirroring where they sit
        // on a physical keyboard, rather than as plain keys in the bottom row.
        // That row already carries both modifiers, the arrows, space, and
        // dismiss; two more plain keys there is what pushed it to 17 caps
        // (~18.7pt wide on a 393pt screen) against the digit row's 12
        // (~29.3pt) — see CompactKeyboardView's slot algorithm. Moving `up`/
        // `down` up to the rows above (mirroring the iPad table, which spreads
        // them into the tab and control rows) and `,`/`.` onto secondaries
        // brings the bottom row to 13 caps (~24.9pt).
        let bottomLetters: [KeyCap] = [
            .character("z"), .character("x"), .character("c"),
            // `*` has no conventional partner the way `,`/`.` do below, but a
            // shell keyboard without a glob is missing a character people type
            // constantly — the number pad on iPad is what made its absence
            // obvious, since it needed one and there was none to repeat.
            .character("v", secondary: .character("*")),
            .character("b"),
            .character("n", secondary: .character(",")),
            .character("m", secondary: .character(".")),
        ]

        return KeyboardLayout(
            rows: [
                [.key(.escape)] + digits
                    // Backspace and forward-delete are the same physical
                    // relationship as the pairing below: hold to repeat the
                    // one you reach for constantly, drag up for the one you
                    // don't.
                    + [.key(.backspace, secondary: .key(.delete), repeats: true)],
                [.key(.tab)] + "qwertyuiop".map { KeyCap.character($0) }
                    + [.key(.up, secondary: .key(.pageUp), repeats: true)],
                [.modifier(.control)] + homeRow
                    + [.key(.return), .key(.down, secondary: .key(.pageDown), repeats: true)],
                [.modifier(.option), .modifier(.shift)]
                    + bottomLetters
                    + [.character(" ", width: .flexible),
                       // No row to spare for home/end, so they ride the
                       // arrows that already point their direction — ←/home
                       // both mean "toward the start", →/end both mean
                       // "toward the end". `KeyCapView`'s drag-up gesture
                       // works the same way here as for a symbol secondary;
                       // see `endTracking` for why a repeating key can still
                       // deliver one.
                       .key(.left, secondary: .key(.home), repeats: true),
                       .key(.right, secondary: .key(.end), repeats: true),
                       .command(.dismissKeyboard),
                       // Last, and alone — see the matching comment on the
                       // iPad table.
                       .command(.closeTab)],
            ],
            // Per CompactKeyboardView's slot algorithm (padding 4, spacing 3),
            // a 393pt-wide portrait screen renders the digit/tab/control rows
            // (12 unit-width caps each) at ~29.3pt, and the modifier-bearing
            // bottom row (13 caps, one flexible) at ~24.9pt — both narrower
            // than Apple's own ~32pt keys, and both needing height to stay
            // hittable. Landscape has to give some of that height back: four
            // rows at the portrait row height would eat over half a ~393pt-
            // tall screen.
            rowHeight: context.orientation == .portrait ? 52 : 40)
    }

    // MARK: Shift

    /// The US QWERTY shifted form of a character.
    ///
    /// This lives here, not in `KeyEncoder`, because it is keyboard knowledge
    /// rather than terminal knowledge: a terminal is sent `A`, never shift+`a`,
    /// so shift must be resolved to a character before anything is encoded.
    /// `KeyEncoder.bytes(for:modifiers:)` accordingly ignores `.shift`.
    public static func shifted(_ character: Character) -> Character {
        if let upper = character.uppercased().first, upper != character {
            return upper
        }
        return punctuationShifts[character] ?? character
    }

    private static let punctuationShifts: [Character: Character] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
        ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]
}
