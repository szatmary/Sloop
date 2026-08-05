import SwiftUI
import SwiftTerm
import SloopKit

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Bridges a SwiftTerm `TerminalView` to a SloopKit `Transport`.
///
/// SwiftTerm calls the coordinator's delegate when the user types; the
/// coordinator forwards those bytes to the transport. Bytes coming back from the
/// transport are fed into the terminal on the main thread.
struct SwiftTermView: PlatformViewRepresentable {
    let transport: Transport

    func makeCoordinator() -> Coordinator { Coordinator(transport: transport) }

    #if os(macOS)
    func makeNSView(context: Context) -> TerminalView { context.coordinator.terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
    #else
    func makeUIView(context: Context) -> TerminalView { context.coordinator.terminalView }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
    #endif

    final class Coordinator: NSObject, TerminalViewDelegate {
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
}
