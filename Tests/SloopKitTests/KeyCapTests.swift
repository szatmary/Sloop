// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class KeyCapTests: XCTestCase {

    func testCharacterCapDefaultsToUnitWidthAndNoRepeat() {
        let cap = KeyCap.character("q")
        XCTAssertEqual(cap.primary, .character("q"))
        XCTAssertNil(cap.secondary)
        XCTAssertEqual(cap.width, .unit)
        XCTAssertFalse(cap.repeats)
    }

    func testCharacterCapCarriesASecondaryValue() {
        let cap = KeyCap.character("1", secondary: .character("~"))
        XCTAssertEqual(cap.primary, .character("1"))
        XCTAssertEqual(cap.secondary, .character("~"))
    }

    func testSpecialKeyCapCanRepeatAndBeWide() {
        let cap = KeyCap.key(.backspace, width: .wide(1.5), repeats: true)
        XCTAssertEqual(cap.primary, .key(.backspace))
        XCTAssertEqual(cap.width, .wide(1.5))
        XCTAssertTrue(cap.repeats)
    }

    func testModifierAndCommandCaps() {
        XCTAssertEqual(KeyCap.modifier(.control).primary, .modifier(.control))
        XCTAssertEqual(KeyCap.command(.dismissKeyboard).primary,
                       .command(.dismissKeyboard))
    }

    /// The characters a cap can produce, which the layout parity test in
    /// Task 5 sums over a whole layout.
    func testReachableCharactersCoversPrimaryAndSecondary() {
        XCTAssertEqual(KeyCap.character("q").reachableCharacters, ["q"])
        XCTAssertEqual(KeyCap.character("1", secondary: .character("~"))
                        .reachableCharacters, ["1", "~"])
        XCTAssertEqual(KeyCap.key(.escape).reachableCharacters, [])
    }
}
