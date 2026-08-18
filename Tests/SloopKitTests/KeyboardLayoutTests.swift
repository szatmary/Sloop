// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class KeyboardLayoutTests: XCTestCase {

    private let padLandscape = KeyboardLayout.Context(idiom: .pad, orientation: .landscape)
    private let padPortrait = KeyboardLayout.Context(idiom: .pad, orientation: .portrait)
    private let phonePortrait = KeyboardLayout.Context(idiom: .phone, orientation: .portrait)
    private let phoneLandscape = KeyboardLayout.Context(idiom: .phone, orientation: .landscape)

    // Reference screen widths for the four contexts above. `Context` itself
    // no longer carries a width (removed as dead production API — nothing in
    // `resolve` ever read it), so the "Frames" tests below, which exercise
    // `frames(width:padding:spacing:)`, pass these explicitly — exactly as
    // `CompactKeyboardView` passes its own `bounds.width` at the real call
    // site, rather than pulling a width off `Context`.
    private let padLandscapeWidth: Double = 1194
    private let padPortraitWidth: Double = 834
    private let phonePortraitWidth: Double = 393
    private let phoneLandscapeWidth: Double = 852

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

    func testEveryLayoutCanCloseItsTab() {
        // `KeyboardAccessoryBar`'s ✕ is the only touch-reachable way to close
        // a session when the software keyboard is up; compact mode replaces
        // that bar entirely, so every layout must carry its own way to close
        // the tab or a session opened in compact mode is unclosable by touch.
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let caps = KeyboardLayout.resolve(for: context).rows.flatMap { $0 }
            XCTAssertTrue(caps.contains { $0.primary == .command(.closeTab) },
                          "no way to close the tab in \(context)")
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

    // MARK: Coverage of the caps that never appear in a `reachableCharacters`
    // set — losing one of these is silent to every test above.

    func testEveryLayoutCarriesEssentialModifiersAndKeys() {
        // `KeyCap.Value` is Equatable but not Hashable, so `contains(where:)`
        // rather than a Set.
        let required: [KeyCap.Value] = [
            .modifier(.shift), .modifier(.control), .modifier(.option),
            .key(.escape), .key(.tab), .key(.return),
        ]
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let caps = KeyboardLayout.resolve(for: context).rows.flatMap { $0 }
            for value in required {
                XCTAssertTrue(caps.contains { $0.primary == value },
                              "\(value) missing from \(context)")
            }
        }
    }

    func testDirectAndShiftedCharactersCoverPrintableASCII() {
        // Neither `testEveryShellCharacterIsReachable` nor
        // `testShiftedDigitsFollowUSQWERTY` alone proves a shifted symbol like
        // `$` or `?` is actually reachable on a given layout: one checks
        // direct characters, the other checks `shifted()` in isolation. This
        // joins them.
        let printableASCII = Set((0x20...0x7e).map { Character(UnicodeScalar($0)!) })
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let direct = KeyboardLayout.resolve(for: context).rows
                .flatMap { $0 }
                .reduce(into: Set<Character>()) { $0.formUnion($1.reachableCharacters) }
            let reachable = direct.union(direct.map(KeyboardLayout.shifted))
            XCTAssertTrue(printableASCII.isSubset(of: reachable),
                          "missing \(printableASCII.subtracting(reachable)) in \(context)")
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

    // MARK: Frames
    //
    // `frames(width:padding:spacing:)` is the grid math `CompactKeyboardView`
    // used to hand-roll in `layoutSubviews` — pulled into SloopKit so it's a
    // pure function a test can check, rather than something only reachable by
    // a reviewer hand-tracing UIKit layout. `padding`/`spacing` below match
    // `CompactKeyboardView`'s own constants (4, 3).

    private let framePadding: Double = 4
    private let frameSpacing: Double = 3
    private var allContexts: [KeyboardLayout.Context] {
        [padLandscape, padPortrait, phonePortrait, phoneLandscape]
    }
    private var allWidths: [Double] {
        [padLandscapeWidth, padPortraitWidth, phonePortraitWidth, phoneLandscapeWidth]
    }

    func testFrameCountMatchesCapCount() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            let capCount = layout.rows.reduce(0) { $0 + $1.count }
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            XCTAssertEqual(frames.count, capCount, "\(context)")
        }
    }

    func testEveryRowsRightEdgeLandsOnWidthMinusPadding() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            var index = 0
            for (rowIndex, row) in layout.rows.enumerated() {
                let last = frames[index + row.count - 1]
                XCTAssertEqual(last.x + last.width, width - framePadding, accuracy: 0.001,
                               "row \(rowIndex) of \(context)")
                index += row.count
            }
        }
    }

    func testNoFrameExceedsBounds() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            for frame in frames {
                XCTAssertGreaterThanOrEqual(frame.x, 0, "\(context)")
                XCTAssertGreaterThanOrEqual(frame.y, 0, "\(context)")
                XCTAssertLessThanOrEqual(frame.x + frame.width, width, "\(context)")
            }
        }
    }

    func testFlexibleKeyIsNeverNarrowerThanAUnitKey() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            var index = 0
            for row in layout.rows {
                let rowFrames = Array(frames[index..<(index + row.count)])
                let unitWidths = zip(row, rowFrames)
                    .filter { $0.0.width == .unit }
                    .map { $0.1.width }
                if let flexIndex = row.firstIndex(where: { $0.width == .flexible }),
                   let widestUnit = unitWidths.max() {
                    XCTAssertGreaterThanOrEqual(rowFrames[flexIndex].width, widestUnit, "\(context)")
                }
                index += row.count
            }
        }
    }

    /// Mirrors `CompactKeyboardView.intrinsicContentSize`'s formula — the
    /// height it reports must actually cover every frame `frames(...)`
    /// produces, or the bottom row would be clipped.
    func testResolvedRowHeightCoversEveryFrame() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            let maxY = frames.map { $0.y + $0.height }.max() ?? 0
            let intrinsicHeight = layout.rowHeight * Double(layout.rows.count) + framePadding * 2
            XCTAssertGreaterThanOrEqual(intrinsicHeight, maxY + framePadding, "\(context)")
        }
    }

    // Hand-computed reference values (task-7 review) for two contexts, pinned
    // exactly rather than only checked against the invariants above.

    func testPhonePortraitSlotWidthsMatchHandComputedValues() {
        let layout = KeyboardLayout.resolve(for: phonePortrait)
        let frames = layout.frames(width: phonePortraitWidth, padding: framePadding, spacing: frameSpacing)
        let flat = layout.rows.flatMap { $0 }
        func frame(where predicate: (KeyCap) -> Bool) -> KeyFrame {
            frames[flat.firstIndex(where: predicate)!]
        }

        // Rows 0–2 (escape/digit, tab/letter, control/home rows): 12 unit
        // caps each on a 393pt-wide screen.
        XCTAssertEqual(frame { $0.primary == .key(.escape) }.width, 29.3333, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .key(.tab) }.width, 29.3333, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .modifier(.control) }.width, 29.3333, accuracy: 0.001)
        // Row 3 (bottom row): 14 caps now (13 + closeTab, added so a session
        // opened in compact mode can be closed by touch) including the
        // flexible space bar, so the unit slot shrinks and the space bar
        // absorbs two slots.
        XCTAssertEqual(frame { $0.primary == .modifier(.option) }.width, 23.0667, accuracy: 0.001)
        XCTAssertEqual(frame { $0.width == .flexible }.width, 46.1333, accuracy: 0.001)
    }

    func testPadLandscapeSlotWidthsMatchHandComputedValues() {
        let layout = KeyboardLayout.resolve(for: padLandscape)
        let frames = layout.frames(width: padLandscapeWidth, padding: framePadding, spacing: frameSpacing)
        let flat = layout.rows.flatMap { $0 }
        func frame(where predicate: (KeyCap) -> Bool) -> KeyFrame {
            frames[flat.firstIndex(where: predicate)!]
        }

        XCTAssertEqual(frame { $0.primary == .character("~") }.width, 59.5789, accuracy: 0.001) // symbol row
        XCTAssertEqual(frame { $0.primary == .key(.escape) }.width, 92.24, accuracy: 0.01)       // digit row unit
        XCTAssertEqual(frame { $0.primary == .key(.backspace) }.width, 138.36, accuracy: 0.01)   // digit row wide
        XCTAssertEqual(frame { $0.primary == .key(.tab) }.width, 96.0833, accuracy: 0.001)       // qwerty row
        XCTAssertEqual(frame { $0.primary == .modifier(.control) }.width, 92.24, accuracy: 0.01) // home row unit
        XCTAssertEqual(frame { $0.primary == .key(.return) }.width, 138.36, accuracy: 0.01)      // home row wide
        // Bottom row: 16 caps now (15 + closeTab).
        XCTAssertEqual(frame { $0.primary == .modifier(.option) }.width, 67.1176, accuracy: 0.01)   // bottom row unit
        XCTAssertEqual(frame { $0.width == .flexible }.width, 134.2353, accuracy: 0.01)             // bottom row space
    }
}
