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
    /// Height of one key row, in points.
    ///
    /// NOTE: these values are unmeasured placeholders (see the Row height
    /// constants below). The task that derives them from real device metrics
    /// is blocked on hardware; only the *relationships* between contexts
    /// (pad shorter than phone portrait; phone landscape shorter than phone
    /// portrait) are load-bearing today.
    public let rowHeight: Double

    /// What a layout varies on.
    public struct Context: Equatable, Sendable, CustomStringConvertible {
        public enum Idiom: Equatable, Sendable { case phone, pad }
        public enum Orientation: Equatable, Sendable { case portrait, landscape }

        public let idiom: Idiom
        public let orientation: Orientation
        public let width: Double

        public init(idiom: Idiom, orientation: Orientation, width: Double) {
            self.idiom = idiom
            self.orientation = orientation
            self.width = width
        }

        public var description: String { "\(idiom)/\(orientation)@\(Int(width))" }
    }

    /// The symbols a shell needs constantly and a prose keyboard buries.
    /// On iPad these are a row; on iPhone they become drag-up secondaries.
    private static let symbols: [Character] =
        ["~", "`", "|", "\\", "/", "[", "]", "{", "}", "<",
         ">", "-", "_", "=", "+", ";", ":", "'"]

    public static func resolve(for context: Context) -> KeyboardLayout {
        switch context.idiom {
        case .pad:   return pad(context)
        case .phone: return phone(context)
        }
    }

    // MARK: Frames

    /// One frame per cap, across all rows, in the same row-major order the
    /// caller built its key views in — so zipping `frames(...)` against those
    /// views lines them up positionally, with no index of its own to drift
    /// out of sync.
    ///
    /// Grid math, not a real layout engine: fixed-width caps (`.unit`,
    /// `.wide`) claim their share of a row first; a `.flexible` cap — the
    /// space bar — absorbs whatever's left, reserved at two slots so it stays
    /// a usable target rather than collapsing to a sliver. This lives here
    /// (pure, platform-agnostic) rather than in `CompactKeyboardView` (UIKit,
    /// unreachable from a package test) specifically so `KeyboardLayoutTests`
    /// can check it against hand-computed values instead of a reviewer having
    /// to hand-trace `layoutSubviews`.
    public func frames(width: Double, padding: Double, spacing: Double) -> [KeyFrame] {
        var result: [KeyFrame] = []
        var y = padding
        for row in rows {
            let fixedSlots = row.reduce(0.0) { total, cap in
                switch cap.width {
                case .unit:            return total + 1
                case .wide(let scale): return total + scale
                case .flexible:        return total
                }
            }
            let gaps = spacing * Double(max(row.count - 1, 0))
            let available = width - padding * 2 - gaps
            let hasFlexible = row.contains { $0.width == .flexible }
            let slotWidth = available / (fixedSlots + (hasFlexible ? 2 : 0))

            var x = padding
            for cap in row {
                let capWidth: Double
                switch cap.width {
                case .unit:            capWidth = slotWidth
                case .wide(let scale): capWidth = slotWidth * scale
                case .flexible:        capWidth = slotWidth * 2
                }
                result.append(KeyFrame(x: x, y: y, width: capWidth, height: rowHeight - spacing))
                x += capWidth + spacing
            }
            y += rowHeight
        }
        return result
    }

    // MARK: iPad — five rows, symbols visible

    private static func pad(_ context: Context) -> KeyboardLayout {
        let symbolRow = symbols.map { KeyCap.character($0) } + [KeyCap.character("\"")]

        return KeyboardLayout(
            rows: [
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
                       .command(.dismissKeyboard)],
            ],
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
            .character("z"), .character("x"), .character("c"), .character("v"),
            .character("b"),
            .character("n", secondary: .character(",")),
            .character("m", secondary: .character(".")),
        ]

        return KeyboardLayout(
            rows: [
                [.key(.escape)] + digits
                    + [.key(.backspace, repeats: true)],
                [.key(.tab)] + "qwertyuiop".map { KeyCap.character($0) }
                    + [.key(.up, repeats: true)],
                [.modifier(.control)] + homeRow
                    + [.key(.return), .key(.down, repeats: true)],
                [.modifier(.option), .modifier(.shift)]
                    + bottomLetters
                    + [.character(" ", width: .flexible),
                       .key(.left, repeats: true), .key(.right, repeats: true),
                       .command(.dismissKeyboard)],
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
