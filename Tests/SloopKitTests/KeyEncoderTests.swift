// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class KeyEncoderTests: XCTestCase {

    func testSimpleControlBytes() {
        XCTAssertEqual(KeyEncoder.bytes(for: .escape), [0x1b])
        XCTAssertEqual(KeyEncoder.bytes(for: .return), [0x0d])
        XCTAssertEqual(KeyEncoder.bytes(for: .backspace), [0x7f])
        XCTAssertEqual(KeyEncoder.bytes(for: .tab), [0x09])
    }

    func testShiftTab() {
        XCTAssertEqual(KeyEncoder.bytes(for: .tab, modifiers: .shift), [0x1b, 0x5b, 0x5a]) // ESC [ Z
    }

    func testArrowsNormalMode() {
        XCTAssertEqual(KeyEncoder.bytes(for: .up), [0x1b, 0x5b, 0x41])    // ESC [ A
        XCTAssertEqual(KeyEncoder.bytes(for: .down), [0x1b, 0x5b, 0x42])  // ESC [ B
        XCTAssertEqual(KeyEncoder.bytes(for: .right), [0x1b, 0x5b, 0x43]) // ESC [ C
        XCTAssertEqual(KeyEncoder.bytes(for: .left), [0x1b, 0x5b, 0x44])  // ESC [ D
    }

    func testArrowsApplicationCursorMode() {
        XCTAssertEqual(KeyEncoder.bytes(for: .up, applicationCursor: true), [0x1b, 0x4f, 0x41])   // ESC O A
        XCTAssertEqual(KeyEncoder.bytes(for: .left, applicationCursor: true), [0x1b, 0x4f, 0x44]) // ESC O D
    }

    func testModifiedArrowUsesCSIRegardlessOfMode() {
        // Ctrl+Up => ESC [ 1 ; 5 A, in both normal and application-cursor mode.
        let expected: [UInt8] = [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x41]
        XCTAssertEqual(KeyEncoder.bytes(for: .up, modifiers: .control), expected)
        XCTAssertEqual(KeyEncoder.bytes(for: .up, modifiers: .control, applicationCursor: true), expected)
    }

    func testHomeEnd() {
        XCTAssertEqual(KeyEncoder.bytes(for: .home), [0x1b, 0x5b, 0x48])                       // ESC [ H
        XCTAssertEqual(KeyEncoder.bytes(for: .end, applicationCursor: true), [0x1b, 0x4f, 0x46]) // ESC O F
    }

    func testEditKeys() {
        XCTAssertEqual(KeyEncoder.bytes(for: .delete), [0x1b, 0x5b, 0x33, 0x7e])   // ESC [ 3 ~
        XCTAssertEqual(KeyEncoder.bytes(for: .pageUp), [0x1b, 0x5b, 0x35, 0x7e])   // ESC [ 5 ~
        XCTAssertEqual(KeyEncoder.bytes(for: .pageDown), [0x1b, 0x5b, 0x36, 0x7e]) // ESC [ 6 ~
    }

    func testModifiedEditKey() {
        // Ctrl+PageUp => ESC [ 5 ; 5 ~
        XCTAssertEqual(KeyEncoder.bytes(for: .pageUp, modifiers: .control),
                       [0x1b, 0x5b, 0x35, 0x3b, 0x35, 0x7e])
    }

    func testFunctionKeys() {
        XCTAssertEqual(KeyEncoder.bytes(for: .function(1)), [0x1b, 0x4f, 0x50])          // ESC O P
        XCTAssertEqual(KeyEncoder.bytes(for: .function(4)), [0x1b, 0x4f, 0x53])          // ESC O S
        XCTAssertEqual(KeyEncoder.bytes(for: .function(5)), [0x1b, 0x5b, 0x31, 0x35, 0x7e]) // ESC [ 15 ~
        XCTAssertEqual(KeyEncoder.bytes(for: .function(12)), [0x1b, 0x5b, 0x32, 0x34, 0x7e]) // ESC [ 24 ~
    }

    func testControlCharacters() {
        XCTAssertEqual(KeyEncoder.bytes(for: "c", modifiers: .control), [0x03]) // Ctrl-C
        XCTAssertEqual(KeyEncoder.bytes(for: "C", modifiers: .control), [0x03]) // case-insensitive
        XCTAssertEqual(KeyEncoder.bytes(for: "a", modifiers: .control), [0x01]) // Ctrl-A
        XCTAssertEqual(KeyEncoder.bytes(for: "[", modifiers: .control), [0x1b]) // Ctrl-[ == ESC
        XCTAssertEqual(KeyEncoder.bytes(for: " ", modifiers: .control), [0x00]) // Ctrl-Space == NUL
    }

    func testOptionPrefixesEscape() {
        XCTAssertEqual(KeyEncoder.bytes(for: "a", modifiers: .option), [0x1b, 0x61])          // ESC a
        XCTAssertEqual(KeyEncoder.bytes(for: "c", modifiers: [.control, .option]), [0x1b, 0x03]) // ESC Ctrl-C
    }

    func testPlainCharacterPassesThrough() {
        XCTAssertEqual(KeyEncoder.bytes(for: "A"), [0x41])
        XCTAssertEqual(KeyEncoder.bytes(for: "z"), [0x7a])
    }

    /// Digits do not follow the `& 0x1F` control rule. Masking would turn
    /// Ctrl-0 into 0x10 (DLE), breaking "tmux prefix then window number".
    func testControlWithDigitsUsesXtermMapping() {
        XCTAssertEqual(KeyEncoder.bytes(for: "0", modifiers: .control), [0x30])
        XCTAssertEqual(KeyEncoder.bytes(for: "1", modifiers: .control), [0x31])
        XCTAssertEqual(KeyEncoder.bytes(for: "9", modifiers: .control), [0x39])
        XCTAssertEqual(KeyEncoder.bytes(for: "2", modifiers: .control), [0x00])
        XCTAssertEqual(KeyEncoder.bytes(for: "3", modifiers: .control), [0x1b])
        XCTAssertEqual(KeyEncoder.bytes(for: "8", modifiers: .control), [0x7f])
    }

    /// tmux's prefix: the combination that could not be typed at all before the
    /// armed modifier reached characters typed on the software keyboard.
    func testControlBIsTmuxPrefix() {
        XCTAssertEqual(KeyEncoder.bytes(for: "b", modifiers: .control), [0x02])
        XCTAssertEqual(KeyEncoder.bytes(for: "B", modifiers: .control), [0x02])
    }

    // MARK: KeyCap.Value dispatch — the pure half of
    // CompactKeyboardView.keyCapView(_:didProduce:)

    /// The reviewer's hand-traced case: iPhone's "5" key drags up to "/"; with
    /// ⇧ armed the terminal must see "?", never shift kept alongside "/".
    func testKeyCapValueCharacterResolvesShiftBeforeEncoding() {
        XCTAssertEqual(
            KeyEncoder.bytes(for: .character("/"), armedModifiers: .shift, applicationCursor: false),
            [0x3f]) // '?'
    }

    func testKeyCapValueCharacterWithoutShiftPassesThrough() {
        XCTAssertEqual(
            KeyEncoder.bytes(for: .character("a"), armedModifiers: [], applicationCursor: false),
            [0x61])
    }

    /// Shift is dropped from the modifier set once resolved into the
    /// character — only the remaining modifiers (here, control) reach
    /// `bytes(for:modifiers:)`.
    func testKeyCapValueCharacterKeepsNonShiftModifiersAfterResolving() {
        XCTAssertEqual(
            KeyEncoder.bytes(for: .character("c"), armedModifiers: [.control, .shift], applicationCursor: false),
            [0x03]) // Ctrl-C: shift upper-cases 'c' to 'C', which control-masks the same as 'c'
    }

    func testKeyCapValueKeyRespectsApplicationCursorMode() {
        XCTAssertEqual(
            KeyEncoder.bytes(for: .key(.up), armedModifiers: [], applicationCursor: true),
            [0x1b, 0x4f, 0x41]) // ESC O A
        XCTAssertEqual(
            KeyEncoder.bytes(for: .key(.up), armedModifiers: [], applicationCursor: false),
            [0x1b, 0x5b, 0x41]) // ESC [ A
    }

    /// `.modifier` and `.command` are the software keyboard's own
    /// affordances — arm a sticky modifier, dismiss the keyboard — and never
    /// reach the remote end.
    func testKeyCapValueModifierAndCommandProduceNoBytes() {
        XCTAssertNil(KeyEncoder.bytes(for: .modifier(.control), armedModifiers: [], applicationCursor: false))
        XCTAssertNil(KeyEncoder.bytes(for: .command(.dismissKeyboard), armedModifiers: [], applicationCursor: false))
    }
}
