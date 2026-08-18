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

    /// Four rows on iPad, and none of them a symbol bar. The bar spelled out
    /// by hand what shift already means — `{` is shift-`[`, `~` is shift-`` ` ``
    /// — and cost a row of height for it, which is the thing a terminal wants
    /// back most.
    func testPadGetsFourRowsAndNoSymbolBar() {
        for context in [padLandscape, padPortrait] {
            let layout = KeyboardLayout.resolve(for: context)
            XCTAssertEqual(layout.rows.count, 4, "\(context)")
            // The top row is the qwerty row, not a bar of symbols above it.
            XCTAssertTrue(layout.rows[0].contains { $0.primary == .character("q") },
                          "\(context): the top row should be the letters")
        }
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

    /// Every character a layout can type: by tap, by drag, or by holding
    /// shift. Shift belongs in the count — it is how a real keyboard reaches
    /// `{`, `:`, `~` and `?`, and it is why this keyboard needs no symbol bar
    /// spelling them out by hand.
    private func typeableCharacters(_ context: KeyboardLayout.Context) -> Set<Character> {
        let direct = KeyboardLayout.resolve(for: context).rows
            .flatMap { $0 }
            .reduce(into: Set<Character>()) { $0.formUnion($1.reachableCharacters) }
        return direct.union(direct.map { KeyboardLayout.shifted($0) })
    }

    func testPhoneAndPadReachTheSameCharacters() {
        XCTAssertEqual(typeableCharacters(phonePortrait), typeableCharacters(padLandscape),
                       "The two layouts must type the same set")
    }

    func testEveryShellCharacterIsReachable() {
        // The characters a shell actually needs, beyond letters and digits.
        let required: Set<Character> = Set("~`|\\/[]{}<>-_=+;:'\",.")
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let reachable = typeableCharacters(context)
            XCTAssertTrue(required.isSubset(of: reachable),
                          "missing \(required.subtracting(reachable)) in \(context)")
        }
    }

    func testLettersAndDigitsAreReachableEverywhere() {
        let required = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            XCTAssertTrue(required.isSubset(of: typeableCharacters(context)))
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
    /// The number pad is excluded because a physical keyboard's isn't exempt
    /// either: `/ * - =` sit on the pad *and* among the symbols there, and
    /// reaching an operator from whichever hand is already there is the point.
    /// Digits are the exception, pinned separately below.
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

    /// Each digit is reachable from exactly one key. The iPad carried a number
    /// row above the letters as well as the pad, which bought a duplicate set
    /// of ten keys at the cost of a row of height and a narrower key
    /// everywhere; the pad is the digit row now.
    func testEachDigitAppearsExactlyOnce() {
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            var counts: [Character: Int] = [:]
            for cap in KeyboardLayout.resolve(for: context).rows.flatMap({ $0 }) {
                for character in cap.reachableCharacters where character.isNumber {
                    counts[character, default: 0] += 1
                }
            }
            for digit in "0123456789" {
                XCTAssertEqual(counts[digit], 1,
                               "'\(digit)' is reachable \(counts[digit] ?? 0) times in \(context)")
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

    /// Rows line up on the right, against the navigation cluster — and with
    /// each other, which is what lets the reverse-L return key be two caps that
    /// read as one.
    ///
    /// Rows come to the same slot total but not the same key count, and each
    /// key costs a gap, so "same width" is not automatic. Where there's no
    /// cluster to align against, as on the phone, rows are centred instead.
    func testRowsLineUpOnTheRight() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            let hasCluster = layout.keypadColumns.contains { $0 > 0 }
            var index = 0
            var mainRightEdges: [Double] = []
            for (row, keypadColumns) in zip(layout.rows, layout.keypadColumns) {
                let mainCount = row.count - keypadColumns
                let first = frames[index]
                let last = frames[index + mainCount - 1]
                mainRightEdges.append(last.x + last.width)
                if !hasCluster {
                    let leading = first.x - framePadding
                    let trailing = (width - framePadding) - (last.x + last.width)
                    XCTAssertEqual(leading, trailing, accuracy: 0.001,
                                   "\(context) should centre when there's no cluster")
                }
                index += row.count
            }
            if hasCluster {
                for edge in mainRightEdges.dropFirst() {
                    XCTAssertEqual(edge, mainRightEdges[0], accuracy: 0.001,
                                   "\(context): rows don't share a right edge")
                }
            }
        }
    }

    /// The pad hangs off the right edge, and its keys sit on one column grid
    /// down the keyboard.
    ///
    /// Compared as a subset rather than an equal list: the pad's bottom row has
    /// a double-wide enter where the rows above have two keys, so it lands on
    /// fewer columns — but every column it does land on has to be one of theirs,
    /// or the pad is drawn crooked.
    func testKeypadIsFlushRightAndOnOneColumnGrid() {
        for (context, width) in zip(allContexts, allWidths) {
            let layout = KeyboardLayout.resolve(for: context)
            guard layout.keypadColumns.contains(where: { $0 > 0 }) else { continue }
            let frames = layout.frames(width: width, padding: framePadding, spacing: frameSpacing)
            var index = 0
            var columnGrid: Set<Int> = []
            var rowsSeen = 0
            for (row, keypadColumns) in zip(layout.rows, layout.keypadColumns) {
                if keypadColumns > 0 {
                    let pad = Array(frames[(index + row.count - keypadColumns)..<(index + row.count)])
                    let last = pad[pad.count - 1]
                    XCTAssertEqual(last.x + last.width, width - framePadding, accuracy: 0.001,
                                   "\(context): pad isn't flush right")
                    let columns = Set(pad.map { Int(($0.x * 100).rounded()) })
                    if rowsSeen == 0 {
                        columnGrid = columns
                    } else {
                        XCTAssertTrue(columns.isSubset(of: columnGrid),
                                      "\(context): pad row \(rowsSeen) is off the column grid")
                    }
                    rowsSeen += 1
                }
                index += row.count
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
        // letter row can afford — the bottom row, at 24.9286 now that the
        // close-tab key is gone from it. The digit and qwerty rows could
        // afford 29.3333 on their own and are centred at the shared unit
        // instead: letters that change width between rows is what that avoids.
        XCTAssertEqual(frame { $0.primary == .key(.escape) }.width, 24.9286, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .key(.tab) }.width, 24.9286, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .modifier(.control) }.width, 24.9286, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .modifier(.option) }.width, 24.9286, accuracy: 0.001)
        // The space bar takes its row's slack, which here is exactly its
        // two-unit floor.
        XCTAssertEqual(frame { $0.width == .flexible }.width, 49.8571, accuracy: 0.001)
    }

    func testPadLandscapeSlotWidthsMatchHandComputedValues() {
        let layout = KeyboardLayout.resolve(for: padLandscape)
        let frames = layout.frames(width: padLandscapeWidth, padding: framePadding, spacing: frameSpacing)
        let flat = layout.rows.flatMap { $0 }
        func frame(where predicate: (KeyCap) -> Bool) -> KeyFrame {
            frames[flat.firstIndex(where: predicate)!]
        }

        // One unit, 47.6596, shared by the letters, the navigation cluster and
        // the number pad — one key size on the keyboard, not three. It is
        // solved for directly: the busiest letter row has to fit all three
        // blocks plus the gap between them, and that equation sets it.
        XCTAssertEqual(frame { $0.primary == .character("q") }.width, 47.6596, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .character("7") }.width, 47.6596, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .key(.up) }.width, 47.6596, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .key(.backspace) }.width, 47.6596, accuracy: 0.001)
        // ANSI widths as multiples of it: control 1.75 at caps lock, shift
        // 2.25, space 4.5.
        XCTAssertEqual(frame { $0.primary == .modifier(.control) }.width, 83.4043, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .modifier(.shift) }.width, 107.2340, accuracy: 0.001)
        XCTAssertEqual(frame { $0.primary == .character(" ") }.width, 214.4681, accuracy: 0.001)
    }
}
