// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// One key on a software keyboard: what it is, not what it emits.
///
/// Deliberately inert. A cap names a value; `KeyEncoder` alone decides the
/// bytes, so the xterm rules that live there — Ctrl+digit, `key & 0x1F`,
/// DECCKM cursor keys — are never reimplemented alongside a layout table.
public struct KeyCap: Equatable, Sendable {

    /// What pressing a key means.
    public enum Value: Equatable, Sendable {
        /// A printable character, encoded via `KeyEncoder.bytes(for:modifiers:)`.
        case character(Character)
        /// A non-character key, encoded via
        /// `KeyEncoder.bytes(for:modifiers:applicationCursor:)`.
        case key(TerminalKey)
        /// Arms a sticky modifier for the next key. Emits nothing itself.
        case modifier(KeyModifiers)
        /// An app-level action. Emits nothing to the remote.
        case command(Command)
        /// A modifier and a key in one press — ⌃C, ⌃D — for the handful of
        /// chords a terminal needs constantly. Distinct from arming `.modifier`
        /// and then tapping a letter: that is two presses and leaves the
        /// modifier armed if the second never comes.
        case chord(KeyModifiers, Character)
        /// Arms the function layer for the next key, turning the digits into
        /// F1–F12. Keyboard-only, like `.modifier`: it emits nothing itself,
        /// and it is not a `KeyModifiers` value because nothing downstream —
        /// no escape sequence, no `key & 0x1F` — has any notion of "fn".
        case functionLayer
        /// A hole in the grid: draws nothing, does nothing, occupies a slot.
        /// The arrow cluster's inverted T is three columns wide and only has
        /// keys in two of its rows; without a way to say "nothing here", the
        /// row below can't sit under the row above.
        case blank
    }

    /// Actions the keyboard asks the app to take, rather than sending onward.
    public enum Command: Equatable, Sendable {
        case dismissKeyboard
        /// Send the pasteboard's contents as if typed. A tablet has no ⌘V, and
        /// the alternative is a long-press on the terminal itself.
        case paste
        /// Put the terminal's selection on the pasteboard. Does nothing when
        /// nothing is selected — there is no sensible guess at what someone
        /// meant to copy, and copying the wrong thing silently is worse than
        /// copying nothing.
        case copy

    }

    /// How much horizontal room a key takes, in grid slots.
    public enum Width: Equatable, Sendable {
        case unit
        case wide(Double)
        /// Absorbs whatever width is left in the row — the space bar. At most
        /// one per row; `KeyboardLayout` tests enforce that.
        case flexible
    }

    /// How a cap joins the key drawn above or below it.
    ///
    /// The reverse-L return key is two caps — a narrow one on the top row, a
    /// wider one below — drawn touching, with only their outer corners rounded,
    /// so they read as the single L-shaped key a keyboard has. Both send
    /// return, which is the whole of what "one key" has to mean here.
    public enum Join: Equatable, Sendable {
        case none
        /// Extends down into the row below, and squares its bottom corners.
        case below
        /// Squares its top corners to meet the cap above.
        case above
    }

    public let primary: Value
    /// Reached by dragging up from the key. Nil where a layout gives symbols
    /// their own row instead of hiding them behind a gesture.
    public let secondary: Value?
    public let width: Width
    /// Whether press-and-hold repeats — true for backspace and arrows, where
    /// holding is how the key is normally used.
    public let repeats: Bool
    public let join: Join

    public init(primary: Value,
                secondary: Value? = nil,
                width: Width = .unit,
                repeats: Bool = false,
                join: Join = .none) {
        self.primary = primary
        self.secondary = secondary
        self.width = width
        self.repeats = repeats
        self.join = join
    }

    // MARK: Convenience constructors

    public static func character(_ character: Character,
                                 secondary: Value? = nil,
                                 width: Width = .unit) -> Self {
        Self(primary: .character(character), secondary: secondary, width: width)
    }

    public static func key(_ terminalKey: TerminalKey,
                           secondary: Value? = nil,
                           width: Width = .unit,
                           repeats: Bool = false,
                           join: Join = .none) -> Self {
        Self(primary: .key(terminalKey), secondary: secondary, width: width,
             repeats: repeats, join: join)
    }

    public static func modifier(_ modifiers: KeyModifiers,
                                width: Width = .unit) -> Self {
        Self(primary: .modifier(modifiers), width: width)
    }

    public static func command(_ command: Command,
                               width: Width = .unit) -> Self {
        Self(primary: .command(command), width: width)
    }

    /// An empty slot, for holding a shape.
    public static let blank = Self(primary: .blank)

    public static let functionLayer = Self(primary: .functionLayer)

    public static func chord(_ modifiers: KeyModifiers, _ character: Character) -> Self {
        Self(primary: .chord(modifiers, character))
    }

    /// Every character this cap can produce, by tap or by drag. Used by the
    /// layout parity test to prove the phone and tablet tables reach the same
    /// character set.
    public var reachableCharacters: Set<Character> {
        var result: Set<Character> = []
        if case .character(let c) = primary { result.insert(c) }
        // `.some(...)` is required: `secondary` is an Optional, and matching a
        // bare case pattern against it does not compile.
        if case .some(.character(let c)) = secondary { result.insert(c) }
        return result
    }
}
