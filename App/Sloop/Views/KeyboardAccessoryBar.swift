// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if os(iOS)
import SwiftUI
import SloopKit

/// The iOS smart-keys bar: the keys a software keyboard lacks, encoded through
/// SloopKit's `KeyEncoder` so they emit correct terminal sequences.
///
/// - ⌃ and ⌥ are **sticky** modifiers: tap to arm (highlighted), and they apply
///   to the next key — a special key from this bar *or* a character typed on
///   the software keyboard — then auto-disarm. The armed state lives on
///   `TerminalController` because typed characters bypass this view entirely;
///   see `TerminalController.armedModifiers`.
/// - A strip of one-tap common Ctrl combos (⌃C, ⌃D, …) covers the shortcuts you
///   reach for most without needing the letter keys.
///
/// `applicationCursor` should reflect the terminal's live DECCKM state so arrows
/// encode as SS3 vs CSI; it defaults to normal mode until wired to SwiftTerm.
struct KeyboardAccessoryBar: View {
    let send: (ArraySlice<UInt8>) -> Void
    /// Read the terminal's live DECCKM state at press time (so arrows follow the
    /// mode set by full-screen apps).
    var applicationCursor: () -> Bool = { false }
    /// The armed modifiers, owned by `TerminalController` so they also apply to
    /// characters typed on the software keyboard.
    @Binding var armed: KeyModifiers

    private var control: Bool { armed.contains(.control) }
    private var option: Bool { armed.contains(.option) }

    private func toggle(_ modifier: KeyModifiers) {
        if armed.contains(modifier) { armed.remove(modifier) } else { armed.insert(modifier) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                modifier("⌃", isOn: control) { toggle(.control) }
                modifier("⌥", isOn: option) { toggle(.option) }
                divider

                special("esc")  { emit(.escape) }
                special("tab")  { emit(.tab) }
                special("←")    { emit(.left) }
                special("↓")    { emit(.down) }
                special("↑")    { emit(.up) }
                special("→")    { emit(.right) }
                special("home") { emit(.home) }
                special("end")  { emit(.end) }
                special("pgup") { emit(.pageUp) }
                special("pgdn") { emit(.pageDown) }
                divider

                ForEach(Array("CDZLRAE"), id: \.self) { letter in
                    special("⌃\(letter)") {
                        send(KeyEncoder.bytes(for: letter, modifiers: .control)[...])
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }

    /// Send a special key with the armed modifiers, then clear them (one-shot).
    private func emit(_ key: TerminalKey) {
        send(KeyEncoder.bytes(for: key, modifiers: armed, applicationCursor: applicationCursor())[...])
        armed = []
    }

    private var divider: some View {
        Divider().frame(height: 22)
    }

    private func special(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func modifier(_ label: String, isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
#endif
