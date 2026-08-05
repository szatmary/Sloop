import SwiftUI
import SwiftTerm
import SloopKit

/// Owns the SwiftTerm `TerminalView` for one session and bridges it to a
/// `Transport`. Shared by `SwiftTermView` (which displays the terminal) and the
/// iOS smart-keys bar (which reads the live cursor-key mode and sends input),
/// so both talk to the same terminal instance.
@MainActor
final class TerminalController: NSObject, ObservableObject, TerminalViewDelegate {
    let terminalView: TerminalView
    private let transport: Transport

    init(transport: Transport) {
        self.transport = transport
        self.terminalView = TerminalView(frame: .zero)
        super.init()
        terminalView.terminalDelegate = self

        transport.onData = { [weak terminalView] bytes in
            DispatchQueue.main.async { terminalView?.feed(byteArray: bytes) }
        }
        transport.onClose = { [weak terminalView] error in
            let message = error.map { "\r\n[sloop] closed: \($0.localizedDescription)\r\n" }
                ?? "\r\n[sloop] connection closed\r\n"
            DispatchQueue.main.async { terminalView?.feed(text: message) }
        }
        transport.start()
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

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        transport.send(data)
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
