import Foundation

/// A local, no-network transport that echoes input and renders a tiny
/// interactive prompt.
///
/// This is the v0 "it runs" target: it lets us exercise the SwiftTerm renderer,
/// the keyboard, and the smart-keys bar on real devices before any SSH/Mosh
/// code exists, and it doubles as a simulator playground.
public final class EchoTransport: Transport {
    public var onData: ((ArraySlice<UInt8>) -> Void)?
    public var onClose: ((Error?) -> Void)?

    public init() {}

    public func start() {
        emit("Sloop \u{2693}  local echo\r\n")
        emit("Type something. Return for a new prompt, Ctrl-C to reset.\r\n\r\n")
        prompt()
    }

    public func send(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            switch byte {
            case 0x0d:            // Return
                emit("\r\n")
                prompt()
            case 0x7f, 0x08:      // Delete / Backspace: erase one cell
                emit("\u{08} \u{08}")
            case 0x03:            // Ctrl-C
                emit("^C\r\n")
                prompt()
            default:
                emit(bytes: [byte][...])
            }
        }
    }

    public func resize(cols: Int, rows: Int) {}

    public func close() { onClose?(nil) }

    private func prompt() { emit("$ ") }
    private func emit(_ text: String) { emit(bytes: ArraySlice(Array(text.utf8))) }
    private func emit(bytes: ArraySlice<UInt8>) { onData?(bytes) }
}
