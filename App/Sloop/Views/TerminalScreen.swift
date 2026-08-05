import SwiftUI
import SloopKit

/// Hosts a live terminal for one session, plus the smart-keys bar on iOS/iPadOS.
struct TerminalScreen: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            SwiftTermView(transport: session.transport)
            #if os(iOS)
            KeyboardAccessoryBar(send: { session.transport.send($0) })
            #endif
        }
        #if os(iOS)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
    }
}
