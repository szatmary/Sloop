// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if os(iOS)
import SwiftUI
import SloopKit

/// What the smart-keys bar collapses to once the keyboard is dismissed.
///
/// A bar in the layout costs 44pt of terminal whether or not it is being used.
/// While reading output you need almost none of it — so this floats *over* the
/// terminal instead, costing no rows, and carries only the keys that matter
/// when you are reading rather than typing: paging, and the way back.
struct FloatingKeyPill: View {
    let send: (ArraySlice<UInt8>) -> Void
    var applicationCursor: () -> Bool = { false }
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            key("pgup") { emit(.pageUp) }
            key("pgdn") { emit(.pageDown) }
            Divider().frame(height: 18)
            Button(action: restore) {
                Image(systemName: "keyboard")
                    .font(.footnote)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show keyboard")
        }
        .padding(.horizontal, 4)
        .background(.thinMaterial, in: Capsule())
        .opacity(0.85)
    }

    private func emit(_ terminalKey: TerminalKey) {
        send(KeyEncoder.bytes(for: terminalKey,
                              applicationCursor: applicationCursor())[...])
    }

    private func key(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
#endif
