// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Which iOS keyboard-adjacent chrome belongs on screen for a terminal pane,
/// given the three facts that determine it.
///
/// This lives in SloopKit (pure, no UIKit/SwiftUI) rather than as computed
/// properties inline in `TerminalPane` specifically so `KeyboardChromeTests`
/// can check every combination against a table instead of a reviewer having
/// to hand-trace `TerminalPane.body` — the same reasoning
/// `KeyboardLayout.frames(...)` documents for itself. It matters more here:
/// this project's app-layer XCTest target (`SloopTests`) only targets
/// `Sloop_macOS`, so logic left inside an iOS-only `View` is unreachable by
/// CI, permanently, not just today.
public enum KeyboardChrome: Equatable, Sendable {
    /// Apple's keyboard is up, or a hardware keyboard is attached: show
    /// `KeyboardAccessoryBar`, the smart-keys row.
    case fullBar
    /// No keyboard — hardware, or software of either style — is up: show the
    /// floating pill, the only way to bring one back.
    case floatingPill
    /// The compact keyboard is up. It already folds the smart-keys bar's
    /// keys — including ⌃ — into itself, so neither the bar nor the pill
    /// belongs on screen: the bar would cost back the height compact mode
    /// exists to reclaim, and the pill would offer a keyboard that's already
    /// there.
    case none

    /// - Parameters:
    ///   - keyboardVisible: Apple's software keyboard is currently on screen
    ///     for this terminal.
    ///   - hardwareKeyboardAttached: a hardware keyboard is attached. When one
    ///     is, no software keyboard appears, so `TerminalController` documents
    ///     `keyboardVisible` as staying `false` whenever this is `true` — an
    ///     invariant enforced there, not here. This function checks the
    ///     hardware term first regardless, so a violation still resolves to
    ///     the safe answer, `.fullBar`, rather than to a state that could
    ///     strand the user with no keyboard and no bar.
    ///   - compactKeyboardActive: Sloop's compact keyboard, rather than
    ///     Apple's, is the current `inputView`.
    public static func resolve(keyboardVisible: Bool,
                                hardwareKeyboardAttached: Bool,
                                compactKeyboardActive: Bool) -> KeyboardChrome {
        if hardwareKeyboardAttached {
            // No software keyboard appears with hardware attached, in either
            // style, so the bar is the only place Esc/Ctrl/arrows exist.
            return .fullBar
        }
        guard keyboardVisible else {
            // Dismissed, regardless of style: the pill is the only way back.
            return .floatingPill
        }
        return compactKeyboardActive ? .none : .fullBar
    }
}
