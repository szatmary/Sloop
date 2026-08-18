// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

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

        return KeyboardLayout(
            rows: [
                [.key(.escape)] + digits
                    + [.key(.backspace, repeats: true)],
                [.key(.tab)] + "qwertyuiop".map { KeyCap.character($0) },
                [.modifier(.control)] + homeRow + [.key(.return)],
                [.modifier(.option), .modifier(.shift)]
                    + "zxcvbnm".map { KeyCap.character($0) }
                    + [.character(","), .character("."),
                       .character(" ", width: .flexible),
                       .key(.left, repeats: true), .key(.down, repeats: true),
                       .key(.up, repeats: true), .key(.right, repeats: true),
                       .command(.dismissKeyboard)],
            ],
            // Portrait keys are ~39pt wide on a 393pt screen and need height to
            // stay hittable. Landscape has to give some of it back: four rows
            // at portrait height would eat over half a ~393pt-tall screen.
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
