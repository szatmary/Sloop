#if os(iOS)
import SwiftUI
import SloopKit

/// The iOS smart-keys bar: the keys a software keyboard lacks, encoded through
/// SloopKit's `KeyEncoder` so they emit correct terminal sequences.
///
/// - ⌃ and ⌥ are **sticky** modifiers: tap to arm (highlighted), and they apply
///   to the next special key, then auto-disarm.
/// - A strip of one-tap common Ctrl combos (⌃C, ⌃D, …) covers the shortcuts you
///   reach for most without needing the letter keys.
///
/// `applicationCursor` should reflect the terminal's live DECCKM state so arrows
/// encode as SS3 vs CSI; it defaults to normal mode until wired to SwiftTerm.
struct KeyboardAccessoryBar: View {
    let send: (ArraySlice<UInt8>) -> Void
    var applicationCursor: Bool = false

    @State private var control = false
    @State private var option = false

    private var armed: KeyModifiers {
        var m: KeyModifiers = []
        if control { m.insert(.control) }
        if option { m.insert(.option) }
        return m
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                modifier("⌃", isOn: control) { control.toggle() }
                modifier("⌥", isOn: option) { option.toggle() }
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
        send(KeyEncoder.bytes(for: key, modifiers: armed, applicationCursor: applicationCursor)[...])
        control = false
        option = false
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
