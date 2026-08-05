import SwiftUI
import SloopKit

/// Hosts a live terminal for one session, plus the smart-keys bar on iOS/iPadOS.
struct TerminalScreen: View {
    let session: TerminalSession
    @StateObject private var controller: TerminalController

    init(session: TerminalSession) {
        self.session = session
        _controller = StateObject(wrappedValue: TerminalController(transport: session.transport))
    }

    var body: some View {
        VStack(spacing: 0) {
            SwiftTermView(controller: controller)
            #if os(iOS)
            KeyboardAccessoryBar(send: { controller.send($0) },
                                 applicationCursor: { controller.applicationCursor })
            #endif
        }
        #if os(iOS)
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(.container, edges: .bottom)
        #endif
    }
}
