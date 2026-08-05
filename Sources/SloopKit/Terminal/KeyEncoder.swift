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
            // Upper-case ASCII letters before masking so 'c' and 'C' both → 0x03.
            let base = (ascii >= 0x61 && ascii <= 0x7a) ? ascii - 0x20 : ascii
            out = [base & 0x1f]
        } else {
            out = Array(String(character).utf8)
        }
        if modifiers.contains(.option) { out.insert(0x1b, at: 0) }
        return out
    }

    // MARK: - Private

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
