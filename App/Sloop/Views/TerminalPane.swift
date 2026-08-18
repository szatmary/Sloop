// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit

/// One terminal, driven by an already-built `TerminalController` (owned by
/// `SessionsModel`). Unlike the old `TerminalScreen`, it does NOT create the
/// controller, so a pane can be hidden (a background tab) without tearing down
/// its connection.
struct TerminalPane: View {
    @ObservedObject var controller: TerminalController
    /// Close this session's tab, from the smart-keys bar on iOS.
    var closeTab: () -> Void = {}
    @State private var confirmingClose = false

    var body: some View {
        #if os(iOS)
        // Computed once and reused at both use sites below, so there is
        // exactly one place — `KeyboardChrome.resolve` — that decides
        // standard vs. compact vs. hardware, rather than two independently
        // derived conditions that could drift apart.
        let chrome = KeyboardChrome.resolve(
            keyboardVisible: controller.keyboardVisible,
            hardwareKeyboardAttached: controller.hardwareKeyboardAttached,
            compactKeyboardActive: controller.compactKeyboardActive)
        #endif
        VStack(spacing: 0) {
            ConnectionStatusBar(state: controller.state) { controller.reconnect() }
            SwiftTermView(controller: controller)
            #if os(iOS)
            if chrome == .fullBar {
                KeyboardAccessoryBar(send: { controller.send($0) },
                                     applicationCursor: { controller.applicationCursor },
                                     armed: $controller.armedModifiers,
                                     closeTab: { confirmingClose = true },
                                     dismissKeyboard: { controller.dismissKeyboard() })
            }
            #endif
        }
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            if chrome == .floatingPill {
                FloatingKeyPill(send: { controller.send($0) },
                                applicationCursor: { controller.applicationCursor },
                                restore: { _ = controller.terminalView.becomeFirstResponder() })
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
            }
        }
        #endif
        // The close key sits in the row your thumbs live in, and it drops a
        // live SSH session — a mis-tap costs real work. Confirm rather than
        // relocate: anywhere on that bar is somewhere you tap constantly.
        .confirmationDialog("Close this session?",
                            isPresented: $confirmingClose,
                            titleVisibility: .visible) {
            Button("Close Session", role: .destructive) { closeTab() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The connection will be closed.")
        }
        #if os(iOS)
        // The compact keyboard's own close-tab key has no SwiftUI state of
        // its own to raise this dialog from — see
        // `TerminalController.onCloseTabRequested`'s doc comment. Wired once
        // per pane rather than on every body evaluation.
        .onAppear { controller.onCloseTabRequested = { confirmingClose = true } }
        #endif
    }
}

/// A thin status bar above the terminal. Hidden while connected (to maximize the
/// terminal), a spinner while connecting, and a red bar with a Reconnect button
/// once the connection drops.
struct ConnectionStatusBar: View {
    let state: ConnectionState
    let reconnect: () -> Void

    var body: some View {
        switch state {
        case .connected:
            EmptyView()
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting…")
                    .font(.footnote)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.yellow.opacity(0.15))
        case .disconnected(let reason):
            HStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(.red)
                Text(reason.map { "Disconnected — \($0)" } ?? "Disconnected")
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button("Reconnect", action: reconnect)
                    .font(.footnote.bold())
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.12))
        }
    }
}
