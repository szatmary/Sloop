// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class KeyboardChromeTests: XCTestCase {

    // MARK: The invariants that keep a user from getting stranded

    func testNoKeyboardAtAllAlwaysYieldsThePillSoThereIsAWayBackToTyping() {
        // The pill is the only affordance that restores a dismissed
        // keyboard. Losing it while no keyboard is up would strand the user
        // with no way to type — regardless of which style they last had.
        for compactKeyboardActive in [false, true] {
            XCTAssertEqual(
                KeyboardChrome.resolve(keyboardVisible: false,
                                        hardwareKeyboardAttached: false,
                                        compactKeyboardActive: compactKeyboardActive),
                .floatingPill,
                "compactKeyboardActive: \(compactKeyboardActive)")
        }
    }

    func testHardwareKeyboardAlwaysYieldsTheFullBarInBothStyles() {
        // A hardware keyboard suppresses the software keyboard entirely, so
        // the compact keyboard's keys (Esc, Ctrl, arrows, ...) are physically
        // unreachable no matter what the setting says — the bar is the only
        // place those keys exist.
        for keyboardVisible in [false, true] {
            for compactKeyboardActive in [false, true] {
                XCTAssertEqual(
                    KeyboardChrome.resolve(keyboardVisible: keyboardVisible,
                                            hardwareKeyboardAttached: true,
                                            compactKeyboardActive: compactKeyboardActive),
                    .fullBar,
                    "keyboardVisible: \(keyboardVisible), compactKeyboardActive: \(compactKeyboardActive)")
            }
        }
    }

    func testCompactKeyboardVisibleWithNoHardwareYieldsNoChrome() {
        // The case the bar-folding exists to produce: the compact keyboard
        // already carries the smart keys, including ⌃, so showing the bar on
        // top of it would both cost back the height compact mode exists to
        // reclaim and put two ⌃ buttons on screen at once.
        XCTAssertEqual(
            KeyboardChrome.resolve(keyboardVisible: true,
                                    hardwareKeyboardAttached: false,
                                    compactKeyboardActive: true),
            .none)
    }

    // MARK: Every combination

    func testAllEightCombinations() {
        let cases: [(keyboardVisible: Bool, hardwareKeyboardAttached: Bool,
                     compactKeyboardActive: Bool, expected: KeyboardChrome)] = [
            (false, false, false, .floatingPill),
            (false, false, true,  .floatingPill),
            (false, true,  false, .fullBar),
            (false, true,  true,  .fullBar),
            (true,  false, false, .fullBar),
            (true,  false, true,  .none),
            // TerminalController documents keyboardVisible as staying false
            // whenever a hardware keyboard is attached; these two rows are
            // that invariant being violated, and pin that the function still
            // resolves to the safe answer rather than trusting the caller.
            (true,  true,  false, .fullBar),
            (true,  true,  true,  .fullBar),
        ]
        for c in cases {
            XCTAssertEqual(
                KeyboardChrome.resolve(keyboardVisible: c.keyboardVisible,
                                        hardwareKeyboardAttached: c.hardwareKeyboardAttached,
                                        compactKeyboardActive: c.compactKeyboardActive),
                c.expected,
                "keyboardVisible: \(c.keyboardVisible), "
                    + "hardwareKeyboardAttached: \(c.hardwareKeyboardAttached), "
                    + "compactKeyboardActive: \(c.compactKeyboardActive)")
        }
    }
}
