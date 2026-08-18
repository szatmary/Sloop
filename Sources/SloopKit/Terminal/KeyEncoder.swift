// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Keyboard modifiers that can be combined with a key.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    /// Alt / Option — sends the key prefixed with ESC (the "meta sends escape"
    /// convention).
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
}

/// Which function key a character stands for while the fn layer is held, in
/// the arrangement every keyboard without an F-row uses: the digits give F1–F10
/// in order, and the two keys past them give F11 and F12.
///
/// Here rather than in the keyboard view so the mapping is testable without a
/// device, and so there is one answer to "what is fn+8" rather than one per
/// caller.
public func functionKeyNumber(forCharacter character: Character) -> Int? {
    switch character {
    case "1"..."9": return character.wholeNumberValue
    case "0":       return 10
    case "-":       return 11
    case "=":       return 12
    default:        return nil
    }
}

/// A non-character key on a terminal keyboard.
public enum TerminalKey: Equatable, Sendable {
    case escape, tab, `return`, backspace, delete
    case up, down, left, right
    case home, end, pageUp, pageDown
    case function(Int) // F1…F12
}

/// Turns keys into the byte sequences a terminal expects. Pure and
/// platform-agnostic so it unit-tests without a device; the UI layer feeds it
/// the current cursor-key mode (read from the live terminal) and the armed
/// modifiers.
///
/// References: xterm's control-sequence conventions — CSI (`ESC [`) vs SS3
/// (`ESC O`) cursor keys, the `1;<n>` modifier parameter, and `Ctrl = key & 0x1F`.
public enum KeyEncoder {

    /// Encode a non-character key.
    ///
    /// - Parameter applicationCursor: when true, unmodified cursor keys use SS3
    ///   (`ESC O A`) instead of CSI (`ESC [ A`) — full-screen apps (vim, less)
    ///   turn this on via DECCKM.
    public static func bytes(for key: TerminalKey,
                             modifiers: KeyModifiers = [],
                             applicationCursor: Bool = false) -> [UInt8] {
        switch key {
        case .escape:    return [0x1b]
        case .return:    return [0x0d]
        case .backspace: return [0x7f]
        case .tab:       return modifiers.contains(.shift) ? [0x1b, 0x5b, 0x5a] : [0x09]

        case .up:    return cursor(0x41, modifiers, applicationCursor) // A
        case .down:  return cursor(0x42, modifiers, applicationCursor) // B
        case .right: return cursor(0x43, modifiers, applicationCursor) // C
        case .left:  return cursor(0x44, modifiers, applicationCursor) // D
        case .home:  return cursor(0x48, modifiers, applicationCursor) // H
        case .end:   return cursor(0x46, modifiers, applicationCursor) // F

        case .delete:   return tilde(3, modifiers)
        case .pageUp:   return tilde(5, modifiers)
        case .pageDown: return tilde(6, modifiers)

        case .function(let n): return functionKey(n, modifiers)
        }
    }

    /// Encode a typed character with modifiers. Control maps to `key & 0x1F`
    /// (so Ctrl-C → 0x03, Ctrl-[ → ESC); Option prefixes ESC.
    public static func bytes(for character: Character, modifiers: KeyModifiers = []) -> [UInt8] {
        var out: [UInt8]
        if modifiers.contains(.control), let ascii = character.asciiValue {
            // Digits don't follow the & 0x1F rule — masking '0' would emit 0x10
            // (DLE) instead of the digit, which breaks things like tmux's
            // "prefix then window number". xterm's mapping is explicit:
            // Ctrl-2 → NUL, Ctrl-3…7 → ESC/FS/GS/RS/US, Ctrl-8 → DEL, and
            // Ctrl-0/1/9 are just the digit.
            if let digit = Self.controlDigit(ascii) {
                out = [digit]
            } else {
                // Upper-case ASCII letters before masking so 'c' and 'C' both → 0x03.
                let base = (ascii >= 0x61 && ascii <= 0x7a) ? ascii - 0x20 : ascii
                out = [base & 0x1f]
            }
        } else {
            out = Array(String(character).utf8)
        }
        if modifiers.contains(.option) { out.insert(0x1b, at: 0) }
        return out
    }

    /// Encode what a key cap produced — the one place that decides "what
    /// bytes does this key send", so the character/key dispatch and the
    /// shift-before-encoding rule aren't duplicated at every call site that
    /// owns a `KeyCap.Value` (currently just `CompactKeyboardView`).
    ///
    /// For `.character`, shift is resolved to the character's shifted form
    /// via `KeyboardLayout.shifted(_:)` and dropped from `armedModifiers`
    /// before encoding — see `bytes(for:modifiers:)`'s doc comment for why:
    /// a terminal receives `A`, never shift+`a`, so `.shift` must never reach
    /// that overload for a character.
    ///
    /// Returns `nil` for `.modifier`, `.command` and `.blank`: none emits
    /// anything to the remote end. The first two are the software keyboard's
    /// own affordances — arming a sticky modifier, dismissing the keyboard —
    /// handled by the caller, and the third is a hole in the grid that holds
    /// the arrow cluster's shape.
    public static func bytes(for value: KeyCap.Value,
                             armedModifiers: KeyModifiers,
                             applicationCursor: Bool) -> [UInt8]? {
        switch value {
        case .character(let character):
            let resolved = armedModifiers.contains(.shift)
                ? KeyboardLayout.shifted(character)
                : character
            return bytes(for: resolved, modifiers: armedModifiers.subtracting(.shift))
        case .key(let terminalKey):
            return bytes(for: terminalKey, modifiers: armedModifiers, applicationCursor: applicationCursor)
        case .chord(let modifiers, let character):
            // The chord's own modifiers, plus anything armed — ⌃C with shift
            // armed is still a legitimate thing to type.
            return bytes(for: character, modifiers: modifiers.union(armedModifiers))
        case .modifier, .command, .blank, .functionLayer:
            return nil
        }
    }

    // MARK: - Private

    /// xterm's Ctrl+digit mapping, or nil when `ascii` isn't a digit.
    private static func controlDigit(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x32: return 0x00        // Ctrl-2 → NUL
        case 0x33: return 0x1b        // Ctrl-3 → ESC
        case 0x34: return 0x1c        // Ctrl-4 → FS
        case 0x35: return 0x1d        // Ctrl-5 → GS
        case 0x36: return 0x1e        // Ctrl-6 → RS
        case 0x37: return 0x1f        // Ctrl-7 → US
        case 0x38: return 0x7f        // Ctrl-8 → DEL
        case 0x30, 0x31, 0x39: return ascii  // Ctrl-0/1/9 → the digit itself
        default: return nil
        }
    }

    /// Cursor / home / end keys (letters A B C D H F).
    private static func cursor(_ letter: UInt8, _ mods: KeyModifiers, _ app: Bool) -> [UInt8] {
        if mods.isEmpty {
            return app ? [0x1b, 0x4f, letter] : [0x1b, 0x5b, letter]
        }
        // ESC [ 1 ; <mod> <letter>
        return [0x1b, 0x5b, 0x31, 0x3b] + digits(modifierParam(mods)) + [letter]
    }

    /// Edit keys encoded as `ESC [ <code> ~` (with an optional `; <mod>`).
    private static func tilde(_ code: Int, _ mods: KeyModifiers) -> [UInt8] {
        var out: [UInt8] = [0x1b, 0x5b] + digits(code)
        if !mods.isEmpty { out += [0x3b] + digits(modifierParam(mods)) }
        out.append(0x7e)
        return out
    }

    private static func functionKey(_ n: Int, _ mods: KeyModifiers) -> [UInt8] {
        // F1–F4: SS3 (ESC O P/Q/R/S), or ESC [ 1 ; <mod> <letter> when modified.
        if (1...4).contains(n) {
            let letter: UInt8 = [0x50, 0x51, 0x52, 0x53][n - 1] // P Q R S
            if mods.isEmpty { return [0x1b, 0x4f, letter] }
            return [0x1b, 0x5b, 0x31, 0x3b] + digits(modifierParam(mods)) + [letter]
        }
        // F5–F12: ESC [ <code> ~ (xterm skips 16 and 22).
        let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
        guard let code = codes[n] else { return [] }
        return tilde(code, mods)
    }

    /// xterm modifier parameter: 1 + shift(1) + alt(2) + control(4).
    private static func modifierParam(_ m: KeyModifiers) -> Int {
        var code = 1
        if m.contains(.shift)   { code += 1 }
        if m.contains(.option)  { code += 2 }
        if m.contains(.control) { code += 4 }
        return code
    }

    private static func digits(_ n: Int) -> [UInt8] { Array(String(n).utf8) }
}
