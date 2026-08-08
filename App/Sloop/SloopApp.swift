import SwiftUI

@main
struct SloopApp: App {
    var body: some Scene {
        WindowGroup {
            HostListView()
        }
        // Hardware-keyboard / menu-bar tab management (macOS menu bar + iPad
        // hardware keyboard). Commands live outside the view tree, so they drive
        // the shared SessionsModel.
        .commands {
            CommandMenu("Terminal") {
                Button("New Local Terminal") { SessionsModel.shared.openLocal() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { SessionsModel.shared.closeSelected() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Next Tab") { SessionsModel.shared.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { SessionsModel.shared.selectPrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }

        // Native macOS Preferences window (⌘,). On iOS the same editor is a
        // sheet from the host list's toolbar.
        #if os(macOS)
        Settings {
            TerminalSettingsView(store: .shared)
                .frame(width: 360)
        }
        #endif
    }
}
