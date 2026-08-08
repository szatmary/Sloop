import XCTest
@testable import SloopKit

final class TerminalAppearanceTests: XCTestCase {

    func testDefaults() {
        let a = TerminalAppearance.default
        XCTAssertEqual(a.fontSize, 13)
        XCTAssertEqual(a.theme, .system)
        XCTAssertEqual(a.cursor, .block)
    }

    func testFontSizeClampedOnInit() {
        XCTAssertEqual(TerminalAppearance(fontSize: 2).fontSize,
                       TerminalAppearance.fontSizeRange.lowerBound)
        XCTAssertEqual(TerminalAppearance(fontSize: 999).fontSize,
                       TerminalAppearance.fontSizeRange.upperBound)
        XCTAssertEqual(TerminalAppearance(fontSize: 16).fontSize, 16)
    }

    func testAdjustFontSizeStaysInRange() {
        var a = TerminalAppearance(fontSize: 31)
        a.adjustFontSize(by: 5)
        XCTAssertEqual(a.fontSize, TerminalAppearance.fontSizeRange.upperBound)

        a = TerminalAppearance(fontSize: 9)
        a.adjustFontSize(by: -5)
        XCTAssertEqual(a.fontSize, TerminalAppearance.fontSizeRange.lowerBound)

        a = TerminalAppearance(fontSize: 14)
        a.adjustFontSize(by: 2)
        XCTAssertEqual(a.fontSize, 16)
    }

    func testCodableRoundTrip() throws {
        let original = TerminalAppearance(fontSize: 18, theme: .dimmed, cursor: .bar)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalAppearance.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodingClampsCorruptFontSize() throws {
        let json = #"{"fontSize": 500, "theme": "dark", "cursor": "underline"}"#
        let decoded = try JSONDecoder().decode(TerminalAppearance.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.fontSize, TerminalAppearance.fontSizeRange.upperBound)
        XCTAssertEqual(decoded.theme, .dark)
        XCTAssertEqual(decoded.cursor, .underline)
    }

    func testDecodingMissingKeysUsesDefaults() throws {
        let decoded = try JSONDecoder().decode(TerminalAppearance.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.theme, .system)
        XCTAssertEqual(decoded.cursor, .block)
        XCTAssertEqual(decoded.fontSize, TerminalAppearance.default.fontSize)
    }

    func testEnumCasesAreExhaustiveForUI() {
        // The settings UI iterates allCases; guard the counts so adding a case
        // without updating the picker is caught here.
        XCTAssertEqual(TerminalAppearance.Theme.allCases.count, 4)
        XCTAssertEqual(TerminalAppearance.CursorStyle.allCases.count, 3)
    }
}
