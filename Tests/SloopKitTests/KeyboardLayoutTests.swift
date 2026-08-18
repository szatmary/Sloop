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

    /// No character is reachable from two different keys in the main block —
    /// two ways to type `[` means one of them is a key that could have carried
    /// something else.
    ///
    /// The number pad is excluded, and duplicating digits there is the entire
    /// point of one: a pad that didn't repeat the number row wouldn't be a
    /// number pad. Its keys are checked for their own consistency by
    /// `testKeypadRepeatsTheNumberRowDeliberately`.
    func testNoDuplicateCharacterWithinTheMainBlock() {
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            var seen: Set<Character> = []
            let layout = KeyboardLayout.resolve(for: context)
            for (row, keypadColumns) in zip(layout.rows, layout.keypadColumns) {
                for cap in row.dropLast(keypadColumns) {
                    for character in cap.reachableCharacters {
                        XCTAssertTrue(seen.insert(character).inserted,
                                      "'\(character)' appears twice in \(context)")
                    }
                }
            }
        }
    }

    /// Everything on the pad is also on the main block — a pad is a second way
    /// to reach keys you already have, never the only way to reach something,
    /// which would make it load-bearing on the one device that has it.
    func testKeypadRepeatsTheNumberRowDeliberately() {
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let layout = KeyboardLayout.resolve(for: context)
            var main: Set<Character> = []
            var pad: Set<Character> = []
            for (row, keypadColumns) in zip(layout.rows, layout.keypadColumns) {
                main.formUnion(row.dropLast(keypadColumns).flatMap(\.reachableCharacters))
                pad.formUnion(row.suffix(keypadColumns).flatMap(\.reachableCharacters))
            }
            XCTAssertTrue(pad.isSubset(of: main),
                          "\(context): \(pad.subtracting(main)) reachable only from the number pad")
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

    /// `home`/`end`/`pageUp`/`pageDown`/`delete` are `.key` values, so they
    /// never show up in a `reachableCharacters` set either — this is the
    /// class of gap that let them go missing from every layout table in the
    /// first place (they were only ever on `KeyboardAccessoryBar`, which
    /// compact mode replaces). Checked by primary OR secondary, since iPad
    /// carries them as plain keys but iPhone hangs them off the arrows/
    /// backspace as drag-up secondaries.
    func testEveryLayoutCanReachPagingAndDeleteKeys() {
        let required: [KeyCap.Value] = [
            .key(.home), .key(.end), .key(.pageUp), .key(.pageDown), .key(.delete),
        ]
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let caps = KeyboardLayout.resolve(for: context).rows.flatMap { $0 }
            for value in required {
                let reachable = caps.contains { $0.primary == value || $0.secondary == value }
                XCTAssertTrue(reachable, "\(value) missing from \(context)")
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

    /// Every letter is the same size as every other letter, in every row and
    /// every context. Sizing each row by its own key count made the 9-key home
    /// row wider than the 10-key top row, and keys that change size between
    /// rows shift under the thumbs while typing.
    ///
    /// Letters specifically, not every unit-width key: the iPad's symbol row
    /// carries about twenty keys and takes a smaller unit of its own, because
    /// the alternative is an alphabet sized to fit the symbols.
    func testEveryUnitKeyIsTheSameWidth() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            let caps = layout.rows.flatMap { $0 }
            let unitWidths = zip(caps, frames)
                .filter { cap, _ in
                    if case .character(let character) = cap.primary {
                        return cap.width == .unit && character.isLetter
                    }
                    return false
                }
                .map(\.1.width)
            guard let first = unitWidths.first else {
                return XCTFail("\(context) has no letter keys at all")
            }
            for unitWidth in unitWidths {
                XCTAssertEqual(unitWidth, first, accuracy: 0.001, "\(context)")
            }
        }
    }

    /// A row that doesn't fill its region is centred rather than left-hung —
    /// the home row sitting flush left with a gap on the right is the tell that
    /// keys were stretched to fit instead of shared.
    ///
    /// "Region" rather than "width" because of the number pad: where one is
    /// present it takes the right-hand end of the row, and the main block is
    /// centred in what's left of the screen, not in the whole of it.
    func testShortRowsAreCentredInTheirRegion() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            var index = 0
            for (rowIndex, (row, keypadColumns)) in zip(layout.rows, layout.keypadColumns).enumerated() {
                let mainCount = row.count - keypadColumns
                let first = frames[index]
                let lastMain = frames[index + mainCount - 1]
                let leading = first.x - framePadding
                let trailing: Double
                if keypadColumns > 0 {
                    // Up to the pad's leading edge, less the gap between blocks.
                    let padStart = frames[index + mainCount].x
                    trailing = padStart - frameSpacing - (lastMain.x + lastMain.width)
                } else {
                    trailing = (width - framePadding) - (lastMain.x + lastMain.width)
                }
                XCTAssertEqual(leading, trailing, accuracy: 0.001,
                               "row \(rowIndex) of \(context) is lopsided")
                index += row.count
            }
        }
    }

    /// The pad hangs off the right edge, and its columns line up down the
    /// keyboard the way a physical one's do.
    func testKeypadIsFlushRightAndAligned() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            guard layout.keypadColumns.contains(where: { $0 > 0 }) else { continue }
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            var index = 0
            var columnXs: [[Double]] = []
            for (row, keypadColumns) in zip(layout.rows, layout.keypadColumns) {
                if keypadColumns > 0 {
                    let pad = Array(frames[(index + row.count - keypadColumns)..<(index + row.count)])
                    let last = pad[pad.count - 1]
                    XCTAssertEqual(last.x + last.width, width - framePadding, accuracy: 0.001,
                                   "\(context): pad isn't flush right")
                    columnXs.append(pad.map(\.x))
                }
                index += row.count
            }
            for column in columnXs.dropFirst() {
                XCTAssertEqual(column, columnXs[0].map { $0 },
                               "\(context): pad columns don't line up")
            }
        }
    }

    /// The space bar absorbs its row's slack, so a row carrying one still runs
    /// the full width — otherwise the bottom row would float in the middle
    /// with dead margins either side.
    func testRowsWithASpaceBarStillFillTheWidth() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            var index = 0
            for (rowIndex, row) in layout.rows.enumerated() {
                if row.contains(where: { $0.width == .flexible }) {
                    let last = frames[index + row.count - 1]
                    XCTAssertEqual(last.x + last.width, width - framePadding, accuracy: 0.001,
                                   "row \(rowIndex) of \(context)")
                }
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

        // Every row draws at the letter unit, which is whatever the tightest
        // letter row can afford. That's the bottom row: 14 caps, 13 fixed slots
        // plus two reserved for the space bar, so (385 - 13×3) / 15 = 23.0667.
        // The digit and qwerty rows could afford 29.3333 on their own and are
        // centred at 23.0667 instead — letters that change width between rows
        // is what this gives up 6pt to avoid.
        XCTAssertEqual(frame { $0.primary == .key(.escape) }.width, 23.0667, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .key(.tab) }.width, 23.0667, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .modifier(.control) }.width, 23.0667, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .modifier(.option) }.width, 23.0667, accuracy: 0.001)
        // The space bar takes its row's slack: 385 - 13×3 - 13×23.0667, which
        // is exactly its two-unit floor here.
        XCTAssertEqual(frame { $0.width == .flexible }.width, 46.1333, accuracy: 0.001)
    }

    func testPadLandscapeSlotWidthsMatchHandComputedValues() {
        let layout = KeyboardLayout.resolve(for: padLandscape)
        let frames = layout.frames(width: padLandscapeWidth, padding: framePadding, spacing: frameSpacing)
        let flat = layout.rows.flatMap { $0 }
        func frame(where predicate: (KeyCap) -> Bool) -> KeyFrame {
            frames[flat.firstIndex(where: predicate)!]
        }

        // Letter unit with the number pad present: every row now lays out in
        // the width left of the pad, and the tightest letter row — the bottom
        // one, 16 caps plus the pad's 3 — sets it at 54.7439. Without the pad
        // it was 67.1176; three columns of number pad is what the difference
        // buys.
        XCTAssertEqual(frame { $0.primary == .key(.escape) }.width, 54.7439, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .key(.tab) }.width, 54.7439, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .modifier(.control) }.width, 54.7439, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .modifier(.option) }.width, 54.7439, accuracy: 0.001)
        // Wide caps stay a multiple of the same unit: 1.5 × 54.7439.
        XCTAssertEqual(frame { $0.primary == .key(.backspace) }.width, 82.1159, accuracy: 0.001)
        // The number pad is drawn at the letter unit, so its keys match the
        // alphabet's rather than being a second size on the same keyboard.
        XCTAssertEqual(frames[flat.count - 1].width, 54.7439, accuracy: 0.001)
        // The symbol row remains the exception: 25 caps can't fit at the letter
        // unit, so it takes the largest that does.
        XCTAssertEqual(frame { $0.primary == .character("~") }.width, 37.6307, accuracy: 0.001)
        XCTAssertEqual(frame { $0.width == .flexible }.width, 146.609, accuracy: 0.001)
    }
}
