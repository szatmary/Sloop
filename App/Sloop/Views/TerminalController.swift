// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SwiftTerm
import SloopKit
#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
private typealias PlatformColor = NSColor
#else
import UIKit
import GameController
private typealias PlatformFont = UIFont
private typealias PlatformColor = UIColor
#endif

/// Owns the SwiftTerm `TerminalView` for one session and bridges it to a
/// `Transport`. Shared by `SwiftTermView` (which displays the terminal) and the
/// iOS smart-keys bar (which reads the live cursor-key mode and sends input),
/// so both talk to the same terminal instance.
///
/// Because transports are one-shot, the controller holds a *factory* and can
/// build a fresh transport on `reconnect()`. It publishes `state` so the UI can
/// show a status indicator and a reconnect affordance.
@MainActor
final class TerminalController: NSObject, ObservableObject, TerminalViewDelegate {
    let terminalView: TerminalView
    @Published private(set) var state: ConnectionState = .connecting

    /// Modifiers armed by the iOS smart-keys bar, applied to the **next typed
    /// character** and then cleared.
    ///
    /// Lives here rather than in the bar because characters typed on the
    /// software keyboard reach SwiftTerm directly and surface through
    /// `send(source:data:)` — the bar never sees them. While the armed state
    /// was private to the bar, ⌃ only affected the bar's own special keys, so
    /// combinations like tmux's ⌃B prefix could not be typed at all.
    @Published var armedModifiers: KeyModifiers = []

    #if os(iOS)
    /// Whether the software keyboard is currently on screen *for this
    /// terminal* — i.e. `terminalView` is first responder and a keyboard is up.
    ///
    /// Driven by the system's show/hide notifications rather than by tracking our
    /// own `dismissKeyboard()` calls, so a keyboard dismissed by the system — a
    /// hardware keyboard being attached, say — is observed too.
    ///
    /// `UIResponder.keyboardWillShowNotification` is posted globally for
    /// *any* view in the process, and `SessionsModel` keeps a
    /// `TerminalController` alive per open tab — including tabs that are
    /// neither visible nor focused — so the show handler is gated on
    /// `terminalView.isFirstResponder`. The hide handler is not: by the time
    /// it fires, a terminal that just resigned already reports
    /// `isFirstResponder == false`, so gating it the same way would make a
    /// genuine self-dismiss (`dismissKeyboard()`, or the system tearing the
    /// keyboard down for this terminal) unable to ever clear its own flag.
    /// Left unconditional, an unrelated keyboard hiding elsewhere in the app
    /// just writes `false` over an already-`false` value on every other
    /// controller — a harmless no-op.
    @Published private(set) var keyboardVisible = false

    /// Whether a hardware keyboard is attached. When one is, no software keyboard
    /// appears and no show/hide notification ever fires, so `keyboardVisible`
    /// stays false and must not be read as "there is room to reclaim".
    ///
    /// `@Published`, driven by `GCKeyboardDidConnect`/`GCKeyboardDidDisconnect`
    /// rather than left a plain computed read of `GCKeyboard.coalesced`,
    /// because nothing else guarantees a re-render when a keyboard attaches
    /// or detaches. Concretely: keyboard dismissed (the pill showing),
    /// attach a Magic Keyboard — no show/hide notification of ours fires (see
    /// `keyboardVisible`'s doc comment), so nothing publishes, and
    /// `TerminalPane` would keep showing the pill instead of the bar until
    /// some unrelated `@Published` change happened to force a redraw. That
    /// is a regression against the pre-compact-keyboard behaviour, where the
    /// bar was always present.
    @Published private(set) var hardwareKeyboardAttached = GCKeyboard.coalesced != nil

    /// Whether Sloop's compact keyboard — as opposed to Apple's — is the
    /// current `inputView`. Set only from `setCompactKeyboard(_:)`, the single
    /// place that installs or clears it, so this can never drift from what's
    /// actually attached to `terminalView`.
    ///
    /// `TerminalPane` reads this (with `keyboardVisible` and
    /// `hardwareKeyboardAttached`) to decide whether `KeyboardAccessoryBar`
    /// belongs on screen: the compact keyboard folds the bar's keys into
    /// itself, so showing both would waste the 44pt compact mode exists to
    /// reclaim and put two ⌃ buttons on screen at once. Published, not a
    /// computed read of `terminalView.inputView`, so a view observing this
    /// controller re-renders the instant the setting changes rather than on
    /// whatever unrelated redraw happens to come next.
    @Published private(set) var compactKeyboardActive = false

    /// Called when the compact keyboard's close-tab key is tapped.
    /// `TerminalPane` sets this (once, in `onAppear`) to raise its own
    /// confirmation dialog before actually closing — the same dialog
    /// `KeyboardAccessoryBar`'s ✕ already goes through. A plain closure, not
    /// `@Published`: nothing observes it as state, it's consumed once per tap
    /// by whichever view wired it, and `CompactKeyboardView` only holds a
    /// weak reference to this controller, not to the SwiftUI view that owns
    /// the confirmation state, so a callback stored here is the bridge
    /// between them.
    var onCloseTabRequested: () -> Void = {}

    /// Tokens for the keyboard show/hide observers, removed in `close()` and
    /// `deinit` so closed/deallocated controllers don't leave dead closures
    /// registered with `NotificationCenter.default` for the life of the process.
    private var keyboardShowObserver: NSObjectProtocol?
    private var keyboardHideObserver: NSObjectProtocol?
    /// Tokens for the hardware-keyboard connect/disconnect observers backing
    /// `hardwareKeyboardAttached`, removed alongside the pair above.
    private var hardwareKeyboardConnectObserver: NSObjectProtocol?
    private var hardwareKeyboardDisconnectObserver: NSObjectProtocol?
    #endif

    private let makeTransport: () -> Transport
    private let onConnectCommand: String?
    private var transport: Transport

    init(makeTransport: @escaping () -> Transport,
         onConnectCommand: String? = nil,
         appearance: TerminalAppearance = .default) {
        self.makeTransport = makeTransport
        self.onConnectCommand = onConnectCommand
        self.terminalView = TerminalView(frame: .zero)
        self.transport = makeTransport()
        super.init()
        terminalView.terminalDelegate = self
        #if os(iOS)
        // SwiftTerm installs its own TerminalAccessory (esc / ctrl / tab / …)
        // as the input accessory view. Sloop ships `KeyboardAccessoryBar`,
        // which covers the same keys plus arrows, paging and one-tap Ctrl
        // combos, so leaving both in place stacked two bars — two Control
        // buttons — above the keyboard and ate the screen. Ours wins because
        // it stays visible with a hardware keyboard attached, when an input
        // accessory view isn't shown at all.
        terminalView.inputAccessoryView = nil
        let center = NotificationCenter.default
        keyboardShowObserver = center.addObserver(
            forName: UIResponder.keyboardWillShowNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Notifications are process-wide, not per-view: every open
                // tab's controller sees them, including backgrounded ones.
                // Only the terminal actually becoming first responder is the
                // one whose keyboard this is.
                guard let self, self.terminalView.isFirstResponder else { return }
                self.keyboardVisible = true
            }
        }
        keyboardHideObserver = center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardVisible = false }
        }
        // Recomputed from `GCKeyboard.coalesced` on both notifications,
        // rather than hard-coded to true/false, so a second hardware
        // keyboard being attached or removed while another is still present
        // resolves correctly instead of assuming exactly one can ever be
        // connected.
        hardwareKeyboardConnectObserver = center.addObserver(
            forName: .GCKeyboardDidConnect,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hardwareKeyboardAttached = GCKeyboard.coalesced != nil }
        }
        hardwareKeyboardDisconnectObserver = center.addObserver(
            forName: .GCKeyboardDidDisconnect,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hardwareKeyboardAttached = GCKeyboard.coalesced != nil }
        }
        #endif
        apply(appearance)
        wire(transport)
        transport.start()
    }

    /// Convenience for a single pre-built transport (tests, previews). Reconnect
    /// reuses the same instance.
    convenience init(transport: Transport) {
        self.init(makeTransport: { transport })
    }

    /// Apply the user's terminal appearance (font, colors, cursor and, on iOS,
    /// keyboard style) to the live `TerminalView`. Safe to call repeatedly as
    /// settings change.
    func apply(_ appearance: TerminalAppearance) {
        terminalView.font = PlatformFont.monospacedSystemFont(
            ofSize: CGFloat(appearance.fontSize), weight: .regular)

        let palette = Self.colors(for: appearance.theme)
        terminalView.nativeForegroundColor = palette.fg
        terminalView.nativeBackgroundColor = palette.bg
        terminalView.caretColor = palette.caret

        // Cursor shape has no public setter, so drive it with DECSCUSR
        // (CSI Ps SP q) — the standard sequence SwiftTerm already understands.
        let code: Int
        switch appearance.cursor {
        case .block: code = 2      // steady block
        case .underline: code = 4  // steady underline
        case .bar: code = 6        // steady bar
        }
        terminalView.feed(text: "\u{1b}[\(code) q")

        // Kept in its own branch so the keyboard concern stays separable
        // from font and palette.
        #if os(iOS)
        setCompactKeyboard(appearance.keyboard == .compact)
        #endif
    }

    private static func colors(
        for theme: TerminalAppearance.Theme
    ) -> (fg: PlatformColor, bg: PlatformColor, caret: PlatformColor) {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> PlatformColor {
            PlatformColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                          blue: CGFloat(b) / 255, alpha: 1)
        }
        switch theme {
        case .system:
            #if os(macOS)
            return (.textColor, .textBackgroundColor, .textColor)
            #else
            return (.label, .systemBackground, .label)
            #endif
        case .dark:
            return (rgb(208, 208, 208), rgb(30, 30, 30), rgb(208, 208, 208))
        case .light:
            return (rgb(26, 26, 26), rgb(255, 255, 255), rgb(26, 26, 26))
        case .dimmed:
            return (rgb(154, 154, 154), rgb(38, 38, 38), rgb(154, 154, 154))
        }
    }

    /// Rebuild the connection after it dropped. No-op unless disconnected.
    func reconnect() {
        guard state.isDisconnected else { return }
        state = .connecting
        terminalView.feed(text: "\r\n[sloop] reconnecting…\r\n")
        let fresh = makeTransport()
        transport = fresh
        wire(fresh)
        fresh.start()
    }

    private func wire(_ transport: Transport) {
        // `transport` is captured weakly on purpose. This closure is stored ON
        // the transport, so capturing it strongly makes it retain itself: no
        // transport would ever deallocate, and each one holds a `Credential`
        // carrying the private key, its passphrase and any password as
        // plaintext strings. Closing a tab would not free them, and every
        // reconnect would pin another copy for the life of the process.
        transport.onOpen = { [weak self, weak transport] in
            DispatchQueue.main.async {
                guard let self, let transport else { return }
                self.state = .connected
                self.runOnConnectCommand(on: transport)
            }
        }
        transport.onData = { [weak terminalView] bytes in
            DispatchQueue.main.async { terminalView?.feed(byteArray: bytes) }
        }
        transport.onClose = { [weak self] error in
            let reason = error?.localizedDescription
            let message = reason.map { "\r\n[sloop] closed: \($0)\r\n" }
                ?? "\r\n[sloop] connection closed\r\n"
            DispatchQueue.main.async {
                self?.terminalView.feed(text: message)
                self?.state = .disconnected(reason: reason)
            }
        }
    }

    /// Type the host's on-connect command into the freshly opened shell.
    ///
    /// Sent as ordinary input rather than run on a separate exec channel, so
    /// the command owns the interactive terminal — `tmux attach` has to, and
    /// an exec channel would run it somewhere the user can't see or interrupt.
    /// It is therefore also transport-agnostic: SSH and Mosh both just carry
    /// the bytes. If the command fails, the shell reports it and the user is
    /// left at a normal prompt, exactly as if they had typed it.
    private func runOnConnectCommand(on transport: Transport) {
        guard let command = onConnectCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else { return }
        transport.send(ArraySlice(Array((command + "\n").utf8)))
    }

    /// The terminal's current DECCKM (application-cursor-keys) state, so the
    /// smart-keys bar encodes arrows as SS3 (`ESC O A`) vs CSI (`ESC [ A`).
    var applicationCursor: Bool {
        terminalView.getTerminal().applicationCursor
    }

    /// Send bytes to the remote end (used by the smart-keys bar).
    func send(_ bytes: ArraySlice<UInt8>) {
        transport.send(bytes)
    }

    #if os(iOS)
    /// Put the software keyboard away, giving its height back to the terminal.
    ///
    /// There is no matching `showKeyboard()`: SwiftTerm's own single-tap handler
    /// already calls `becomeFirstResponder()`, so tapping the terminal brings it
    /// back.
    func dismissKeyboard() {
        _ = terminalView.resignFirstResponder()
    }

    /// Swap between Apple's keyboard and Sloop's compact one.
    ///
    /// `inputView` is the same hook SwiftTerm's own `KeyboardView` uses; nil means
    /// the system keyboard. Reloading is required because UIKit caches the input
    /// view for as long as the responder stays first responder.
    ///
    /// Idempotent by construction, not just convention: `apply(_:)` calls this
    /// on every appearance change, not only when the compact-keyboard setting
    /// itself changes. Rebuilding unconditionally would tear down and
    /// recreate the live `CompactKeyboardView` — killing any touch currently
    /// being tracked — every time the font size or theme changes while it's
    /// on screen. `compactKeyboardActive` mirrors the outcome for
    /// `TerminalPane` to read.
    func setCompactKeyboard(_ enabled: Bool) {
        let alreadyEnabled = terminalView.inputView is CompactKeyboardView
        guard enabled != alreadyEnabled else { return }
        terminalView.inputView = enabled ? CompactKeyboardView(controller: self) : nil
        compactKeyboardActive = enabled
        if terminalView.isFirstResponder {
            terminalView.reloadInputViews()
        }
    }
    #endif

    /// Tear down the connection — called when the session's tab is closed.
    func close() {
        transport.close()
        #if os(iOS)
        removeKeyboardObservers()
        // Belt-and-braces: the controller shouldn't hold a callback into a
        // view it's finished with. `TerminalPane` already avoids capturing
        // the controller (or view) in this closure, so this isn't load-
        // bearing for the retain cycle — but `close()` isn't guaranteed to
        // run on every path, so it's not a substitute for that fix either.
        onCloseTabRequested = {}
        #endif
    }

    #if os(iOS)
    private func removeKeyboardObservers() {
        let center = NotificationCenter.default
        if let observer = keyboardShowObserver {
            center.removeObserver(observer)
            keyboardShowObserver = nil
        }
        if let observer = keyboardHideObserver {
            center.removeObserver(observer)
            keyboardHideObserver = nil
        }
        if let observer = hardwareKeyboardConnectObserver {
            center.removeObserver(observer)
            hardwareKeyboardConnectObserver = nil
        }
        if let observer = hardwareKeyboardDisconnectObserver {
            center.removeObserver(observer)
            hardwareKeyboardDisconnectObserver = nil
        }
    }
    #endif

    deinit {
        // `close()` (called by `SessionsModel.close(_:)`) already removes
        // these, but a controller built and dropped without going through
        // `close()` — a unit test, say — must not leak the observers either.
        #if os(iOS)
        let center = NotificationCenter.default
        if let observer = keyboardShowObserver { center.removeObserver(observer) }
        if let observer = keyboardHideObserver { center.removeObserver(observer) }
        if let observer = hardwareKeyboardConnectObserver { center.removeObserver(observer) }
        if let observer = hardwareKeyboardDisconnectObserver { center.removeObserver(observer) }
        #endif
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !armedModifiers.isEmpty else {
            transport.send(data)
            return
        }
        let modifiers = armedModifiers
        armedModifiers = []
        // Only a single ASCII byte is a keystroke worth re-encoding. Pastes and
        // multi-byte (IME, emoji) input pass through untouched rather than
        // being mangled by a control mask.
        guard data.count == 1, let byte = data.first, byte < 0x80 else {
            transport.send(data)
            return
        }
        let character = Character(UnicodeScalar(byte))
        transport.send(KeyEncoder.bytes(for: character, modifiers: modifiers)[...])
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        transport.resize(cols: newCols, rows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
