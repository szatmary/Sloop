#if os(iOS)
import SwiftUI

/// A scrolling row of keys the software keyboard lacks — Esc, Tab, Ctrl-C, and
/// arrows — each sending the matching byte sequence straight to the transport.
///
/// A full modifier model (sticky Ctrl/Alt) comes later; this covers the keys you
/// reach for most in a shell.
struct KeyboardAccessoryBar: View {
    let send: (ArraySlice<UInt8>) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key("esc") { bytes([0x1b]) }
                key("tab") { bytes([0x09]) }
                key("⌃C")  { bytes([0x03]) }
                key("←")   { bytes([0x1b, 0x5b, 0x44]) }
                key("↓")   { bytes([0x1b, 0x5b, 0x42]) }
                key("↑")   { bytes([0x1b, 0x5b, 0x41]) }
                key("→")   { bytes([0x1b, 0x5b, 0x43]) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.thinMaterial)
    }

    private func bytes(_ value: [UInt8]) { send(value[...]) }

    private func key(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
#endif
