// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// User-tunable look and input of the terminal: font size, color theme, cursor
/// shape, and (iOS only) keyboard style.
///
/// This is the platform-agnostic *model* — it holds no SwiftTerm/UIKit types, so
/// it lives in SloopKit and is unit-tested on Linux. The app layer maps it onto
/// the SwiftTerm `TerminalView` (font, palette, caret, input view) and persists
/// it.
public struct TerminalAppearance: Codable, Equatable, Sendable {
    /// Point size of the monospaced terminal font. Kept in a sane range so the
    /// grid stays usable; see `fontSizeRange`.
    public var fontSize: Double
    public var theme: Theme
    public var cursor: CursorStyle
    public var keyboard: KeyboardStyle

    /// Whether Sloop suggests commands from what you've typed before.
    ///
    /// Off is a real off: no bar, and nothing recorded. A switch that only hid
    /// the suggestions while still keeping every command line in a file would
    /// be the more dishonest of the two things it could mean, and the file is
    /// the part worth having a choice about — command lines carry tokens,
    /// passwords and the names of machines people would rather not write down.
    public var suggestions: Bool

    private enum CodingKeys: String, CodingKey {
        case fontSize, theme, cursor, keyboard, suggestions
    }

    /// Allowed font sizes, in points. Values are clamped into this range.
    public static let fontSizeRange: ClosedRange<Double> = 8...32

    public static let `default` = TerminalAppearance(fontSize: 13, theme: .system, cursor: .block,
                                                     keyboard: .standard, suggestions: true)

    /// Which colors the terminal draws with.
    public enum Theme: String, Codable, CaseIterable, Sendable {
        /// Follow the OS light/dark setting.
        case system
        case dark
        case light
        /// A muted, low-contrast dark palette.
        case dimmed
    }

    /// The shape of the text cursor.
    public enum CursorStyle: String, Codable, CaseIterable, Sendable {
        case block
        case underline
        case bar
    }

    /// Which software keyboard a session gets on iOS.
    ///
    /// This is input, not look, and this type documents itself as the terminal's
    /// appearance — a deliberate trade. A parallel preferences model and store for
    /// a single enum is more structure than the problem earns. If input settings
    /// grow (repeat rate, Caps Lock remapping, hardware chords), split them out
    /// then and widen this type's doc comment at that point.
    public enum KeyboardStyle: String, Codable, CaseIterable, Sendable {
        /// Apple's keyboard, with Sloop's smart-keys bar above it.
        case standard
        /// Sloop's compact keyboard, with the smart-keys bar folded into it.
        case compact
    }

    /// Creates an appearance, clamping `fontSize` into `fontSizeRange` so an
    /// out-of-range persisted or user value can never produce an unusable grid.
    public init(fontSize: Double = 13, theme: Theme = .system, cursor: CursorStyle = .block,
                keyboard: KeyboardStyle = .standard, suggestions: Bool = true) {
        self.fontSize = TerminalAppearance.clampFontSize(fontSize)
        self.theme = theme
        self.cursor = cursor
        self.keyboard = keyboard
        self.suggestions = suggestions
    }

    /// Decoding goes through the same clamping, so a hand-edited or corrupt
    /// stored value is normalized rather than trusted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let size = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? TerminalAppearance.default.fontSize
        self.fontSize = TerminalAppearance.clampFontSize(size)
        self.theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .system
        self.cursor = try c.decodeIfPresent(CursorStyle.self, forKey: .cursor) ?? .block
        self.keyboard = try c.decodeIfPresent(KeyboardStyle.self, forKey: .keyboard) ?? .standard
        self.suggestions = try c.decodeIfPresent(Bool.self, forKey: .suggestions) ?? true
    }

    /// Bump the font size by `delta` points, staying within range.
    public mutating func adjustFontSize(by delta: Double) {
        fontSize = TerminalAppearance.clampFontSize(fontSize + delta)
    }

    private static func clampFontSize(_ size: Double) -> Double {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}
