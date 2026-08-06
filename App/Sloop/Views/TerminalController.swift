import SwiftUI
import SwiftTerm
import SloopKit

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

    private let makeTransport: () -> Transport
    private var transport: Transport

    init(makeTransport: @escaping () -> Transport) {
        self.makeTransport = makeTransport
        self.terminalView = TerminalView(frame: .zero)
        self.transport = makeTransport()
        super.init()
        terminalView.terminalDelegate = self
        wire(transport)
        transport.start()
    }

    /// Convenience for a single pre-built transport (tests, previews). Reconnect
    /// reuses the same instance.
    convenience init(transport: Transport) {
        self.init(makeTransport: { transport })
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
        transport.onOpen = { [weak self] in
            DispatchQueue.main.async { self?.state = .connected }
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
