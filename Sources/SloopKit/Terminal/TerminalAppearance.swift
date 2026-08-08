import Foundation

/// User-tunable look of the terminal: font size, color theme, and cursor shape.
///
/// This is the platform-agnostic *model* — it holds no SwiftTerm/UIKit types, so
/// it lives in SloopKit and is unit-tested on Linux. The app layer maps it onto
/// the SwiftTerm `TerminalView` (font, palette, caret) and persists it.
public struct TerminalAppearance: Codable, Equatable, Sendable {
    /// Point size of the monospaced terminal font. Kept in a sane range so the
    /// grid stays usable; see `fontSizeRange`.
    public var fontSize: Double
    public var theme: Theme
    public var cursor: CursorStyle

    private enum CodingKeys: String, CodingKey {
        case fontSize, theme, cursor
    }

    /// Allowed font sizes, in points. Values are clamped into this range.
    public static let fontSizeRange: ClosedRange<Double> = 8...32

    public static let `default` = TerminalAppearance(fontSize: 13, theme: .system, cursor: .block)

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

    /// Creates an appearance, clamping `fontSize` into `fontSizeRange` so an
    /// out-of-range persisted or user value can never produce an unusable grid.
    public init(fontSize: Double = 13, theme: Theme = .system, cursor: CursorStyle = .block) {
        self.fontSize = TerminalAppearance.clampFontSize(fontSize)
        self.theme = theme
        self.cursor = cursor
    }

    /// Decoding goes through the same clamping, so a hand-edited or corrupt
    /// stored value is normalized rather than trusted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let size = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? TerminalAppearance.default.fontSize
        self.fontSize = TerminalAppearance.clampFontSize(size)
        self.theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .system
        self.cursor = try c.decodeIfPresent(CursorStyle.self, forKey: .cursor) ?? .block
    }

    /// Bump the font size by `delta` points, staying within range.
    public mutating func adjustFontSize(by delta: Double) {
        fontSize = TerminalAppearance.clampFontSize(fontSize + delta)
    }

    private static func clampFontSize(_ size: Double) -> Double {
        min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}
