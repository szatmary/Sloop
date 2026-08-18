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
    }

    /// Actions the keyboard asks the app to take, rather than sending onward.
    public enum Command: Equatable, Sendable {
        case dismissKeyboard
        case closeTab
    }

    /// How much horizontal room a key takes, in grid slots.
    public enum Width: Equatable, Sendable {
        case unit
        case wide(Double)
        /// Absorbs whatever width is left in the row — the space bar. At most
        /// one per row; `KeyboardLayout` tests enforce that.
        case flexible
    }

    public let primary: Value
    /// Reached by dragging up from the key. Nil where a layout gives symbols
    /// their own row instead of hiding them behind a gesture.
    public let secondary: Value?
    public let width: Width
    /// Whether press-and-hold repeats — true for backspace and arrows, where
    /// holding is how the key is normally used.
    public let repeats: Bool

    public init(primary: Value,
                secondary: Value? = nil,
                width: Width = .unit,
                repeats: Bool = false) {
        self.primary = primary
        self.secondary = secondary
        self.width = width
        self.repeats = repeats
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
                           repeats: Bool = false) -> Self {
        Self(primary: .key(terminalKey), secondary: secondary, width: width, repeats: repeats)
    }

    public static func modifier(_ modifiers: KeyModifiers,
                                width: Width = .unit) -> Self {
        Self(primary: .modifier(modifiers), width: width)
    }

    public static func command(_ command: Command,
                               width: Width = .unit) -> Self {
        Self(primary: .command(command), width: width)
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
