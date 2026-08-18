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

    /// Apply the user's terminal appearance (font, colors, cursor) to the live
    /// `TerminalView`. Safe to call repeatedly as settings change.
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

    /// Tear down the connection — called when the session's tab is closed.
    func close() {
        transport.close()
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
