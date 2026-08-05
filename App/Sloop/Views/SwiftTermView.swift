import SwiftUI
import SwiftTerm

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Displays the SwiftTerm `TerminalView` owned by a `TerminalController`.
/// The controller does the transport bridging; this is just the SwiftUI wrapper.
struct SwiftTermView: PlatformViewRepresentable {
    let controller: TerminalController

    #if os(macOS)
    func makeNSView(context: Context) -> TerminalView { controller.terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
    #else
    func makeUIView(context: Context) -> TerminalView { controller.terminalView }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
    #endif
}
