import SwiftUI
import SloopKit

/// Hosts a live terminal for one session, plus a connection-status bar and the
/// smart-keys bar on iOS/iPadOS.
struct TerminalScreen: View {
    let session: TerminalSession
    @StateObject private var controller: TerminalController
    @ObservedObject private var appearance = AppearanceStore.shared

    init(session: TerminalSession) {
        self.session = session
        _controller = StateObject(wrappedValue: TerminalController(
            makeTransport: session.newTransport,
            appearance: AppearanceStore.shared.appearance))
    }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionStatusBar(state: controller.state) { controller.reconnect() }
            SwiftTermView(controller: controller)
            #if os(iOS)
            KeyboardAccessoryBar(send: { controller.send($0) },
                                 applicationCursor: { controller.applicationCursor })
            #endif
        }
        // Restyle the live terminal when the user changes appearance settings.
        .onChange(of: appearance.appearance) { _, new in controller.apply(new) }
        #if os(iOS)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
    }
}

/// A thin status bar above the terminal. Hidden while connected (to maximize the
/// terminal), a spinner while connecting, and a red bar with a Reconnect button
/// once the connection drops.
private struct ConnectionStatusBar: View {
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
