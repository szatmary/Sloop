// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class KeyboardLayoutTests: XCTestCase {

    private let padLandscape = KeyboardLayout.Context(
        idiom: .pad, orientation: .landscape, width: 1194)
    private let padPortrait = KeyboardLayout.Context(
        idiom: .pad, orientation: .portrait, width: 834)
    private let phonePortrait = KeyboardLayout.Context(
        idiom: .phone, orientation: .portrait, width: 393)
    private let phoneLandscape = KeyboardLayout.Context(
        idiom: .phone, orientation: .landscape, width: 852)

    // MARK: Shape

    func testPadGetsFiveRowsIncludingADedicatedSymbolRow() {
        XCTAssertEqual(KeyboardLayout.resolve(for: padLandscape).rows.count, 5)
        XCTAssertEqual(KeyboardLayout.resolve(for: padPortrait).rows.count, 5)
    }

    func testPhoneDropsTheSymbolRow() {
        XCTAssertEqual(KeyboardLayout.resolve(for: phonePortrait).rows.count, 4)
        XCTAssertEqual(KeyboardLayout.resolve(for: phoneLandscape).rows.count, 4)
    }

    func testPadHidesNothingBehindAGesture() {
        for cap in KeyboardLayout.resolve(for: padLandscape).rows.flatMap({ $0 }) {
            XCTAssertNil(cap.secondary,
                         "iPad has room for a symbol row; nothing should need a drag")
        }
    }

    func testPhoneUsesSecondariesToReplaceTheSymbolRow() {
        let caps = KeyboardLayout.resolve(for: phonePortrait).rows.flatMap { $0 }
        XCTAssertFalse(caps.filter { $0.secondary != nil }.isEmpty)
    }

    // MARK: The invariant that keeps the two tables honest

    func testPhoneAndPadReachTheSameCharacters() {
        func characters(_ context: KeyboardLayout.Context) -> Set<Character> {
            KeyboardLayout.resolve(for: context).rows
                .flatMap { $0 }
                .reduce(into: Set<Character>()) { $0.formUnion($1.reachableCharacters) }
        }
        XCTAssertEqual(characters(phonePortrait), characters(padLandscape),
                       "Dropping the symbol row must not drop any character")
    }

    func testEveryShellCharacterIsReachable() {
        // The characters a shell actually needs, beyond letters and digits.
        let required: Set<Character> = Set("~`|\\/[]{}<>-_=+;:'\",.")
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let reachable = KeyboardLayout.resolve(for: context).rows
                .flatMap { $0 }
                .reduce(into: Set<Character>()) { $0.formUnion($1.reachableCharacters) }
            XCTAssertTrue(required.isSubset(of: reachable),
                          "missing \(required.subtracting(reachable)) in \(context)")
        }
    }

    func testLettersAndDigitsAreReachableEverywhere() {
        let required = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let reachable = KeyboardLayout.resolve(for: context).rows
                .flatMap { $0 }
                .reduce(into: Set<Character>()) { $0.formUnion($1.reachableCharacters) }
            XCTAssertTrue(required.isSubset(of: reachable))
        }
    }

    // MARK: Well-formedness

    func testAtMostOneFlexibleKeyPerRow() {
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            for (index, row) in KeyboardLayout.resolve(for: context).rows.enumerated() {
                let flexible = row.filter { $0.width == .flexible }.count
                XCTAssertLessThanOrEqual(flexible, 1, "row \(index) of \(context)")
            }
        }
    }

    func testNoDuplicateCharacterWithinALayout() {
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            var seen: Set<Character> = []
            for cap in KeyboardLayout.resolve(for: context).rows.flatMap({ $0 }) {
                for character in cap.reachableCharacters {
                    XCTAssertTrue(seen.insert(character).inserted,
                                  "'\(character)' appears twice in \(context)")
                }
            }
        }
    }

    func testEveryLayoutCanDismissItself() {
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let caps = KeyboardLayout.resolve(for: context).rows.flatMap { $0 }
            XCTAssertTrue(caps.contains { $0.primary == .command(.dismissKeyboard) },
                          "no way back to the terminal in \(context)")
        }
    }

    func testBackspaceAndArrowsRepeat() {
        for context in [padLandscape, phonePortrait] {
            let caps = KeyboardLayout.resolve(for: context).rows.flatMap { $0 }
            for value in [KeyCap.Value.key(.backspace), .key(.left), .key(.up)] {
                let cap = caps.first { $0.primary == value }
                XCTAssertNotNil(cap, "\(value) missing from \(context)")
                XCTAssertEqual(cap?.repeats, true, "\(value) should repeat")
            }
        }
    }

    // MARK: Row height

    func testRowHeightIsShorterOnPadThanPhonePortrait() {
        // iPad keys are wide, so they can afford to be short. iPhone portrait
        // keys are narrow and need height to stay hittable.
        XCTAssertLessThan(KeyboardLayout.resolve(for: padLandscape).rowHeight,
                          KeyboardLayout.resolve(for: phonePortrait).rowHeight)
    }

    func testPhoneLandscapeUsesShorterRowsThanPhonePortrait() {
        // A 4-row keyboard at portrait height would eat over half of a
        // ~393pt-tall landscape phone screen.
        XCTAssertLessThan(KeyboardLayout.resolve(for: phoneLandscape).rowHeight,
                          KeyboardLayout.resolve(for: phonePortrait).rowHeight)
    }

    // MARK: Shift

    func testShiftedLettersUpperCase() {
        XCTAssertEqual(KeyboardLayout.shifted("a"), "A")
        XCTAssertEqual(KeyboardLayout.shifted("z"), "Z")
    }

    func testShiftedDigitsFollowUSQWERTY() {
        XCTAssertEqual(KeyboardLayout.shifted("1"), "!")
        XCTAssertEqual(KeyboardLayout.shifted("2"), "@")
        XCTAssertEqual(KeyboardLayout.shifted("3"), "#")
        XCTAssertEqual(KeyboardLayout.shifted("4"), "$")
        XCTAssertEqual(KeyboardLayout.shifted("5"), "%")
        XCTAssertEqual(KeyboardLayout.shifted("6"), "^")
        XCTAssertEqual(KeyboardLayout.shifted("7"), "&")
        XCTAssertEqual(KeyboardLayout.shifted("8"), "*")
        XCTAssertEqual(KeyboardLayout.shifted("9"), "(")
        XCTAssertEqual(KeyboardLayout.shifted("0"), ")")
    }

    func testShiftedPunctuationFollowsUSQWERTY() {
        XCTAssertEqual(KeyboardLayout.shifted("-"), "_")
        XCTAssertEqual(KeyboardLayout.shifted("="), "+")
        XCTAssertEqual(KeyboardLayout.shifted("["), "{")
        XCTAssertEqual(KeyboardLayout.shifted("]"), "}")
        XCTAssertEqual(KeyboardLayout.shifted("\\"), "|")
        XCTAssertEqual(KeyboardLayout.shifted(";"), ":")
        XCTAssertEqual(KeyboardLayout.shifted("'"), "\"")
        XCTAssertEqual(KeyboardLayout.shifted(","), "<")
        XCTAssertEqual(KeyboardLayout.shifted("."), ">")
        XCTAssertEqual(KeyboardLayout.shifted("/"), "?")
        XCTAssertEqual(KeyboardLayout.shifted("`"), "~")
    }

    func testShiftLeavesAlreadyShiftedCharactersAlone() {
        XCTAssertEqual(KeyboardLayout.shifted("A"), "A")
        XCTAssertEqual(KeyboardLayout.shifted("!"), "!")
    }
}
