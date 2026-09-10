// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

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
