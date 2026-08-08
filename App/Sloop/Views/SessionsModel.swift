import SwiftUI
import SloopKit

/// The app-layer wrapper around `OpenSessions` (the pure tab model in SloopKit).
///
/// Crucially it *owns the `TerminalController` for each open session*, not the
/// view. That keeps every tab's connection alive while it's in the background —
/// a controller tied to a view would be torn down the moment the tab scrolls
/// off-screen. Controllers are created when a session opens and closed when its
/// tab closes.
@MainActor
final class SessionsModel: ObservableObject {
    /// Shared instance so app-level menu/keyboard commands (which live outside
    /// the view tree) drive the same tabs the UI shows. Single-window today; a
    /// future multi-window app would use one model per scene instead.
    static let shared = SessionsModel()

    @Published private(set) var open = OpenSessions()

    private var controllers: [TerminalSession.ID: TerminalController] = [:]

    var sessions: [TerminalSession] { open.sessions }
    var selectedID: TerminalSession.ID? { open.selectedID }
    var isEmpty: Bool { open.isEmpty }
    var count: Int { open.count }

    /// Open a session as a new tab, build its controller (which starts
    /// connecting immediately), and make it active.
    func openSession(_ session: TerminalSession) {
        controllers[session.id] = TerminalController(
            makeTransport: session.newTransport,
            appearance: AppearanceStore.shared.appearance)
        open.open(session)
    }

    /// Make an open tab active.
    func select(_ id: TerminalSession.ID) {
        open.select(id)
    }

    /// Open a fresh local (echo) terminal tab — the ⌘T action.
    func openLocal() {
        openSession(.localEcho())
    }

    /// Close the active tab — the ⌘W action. No-op when nothing is open.
    func closeSelected() {
        if let id = open.selectedID { close(id) }
    }

    /// Cycle the active tab (⌘⇧] / ⌘⇧[). No-ops when nothing is open.
    func selectNext() { open.selectNext() }
    func selectPrevious() { open.selectPrevious() }

    /// Close a tab: tear down its connection and drop its controller.
    func close(_ id: TerminalSession.ID) {
        controllers[id]?.close()
        controllers[id] = nil
        open.close(id)
    }

    /// The live controller for an open session (nil if it isn't open).
    func controller(for session: TerminalSession) -> TerminalController? {
        controllers[session.id]
    }

    /// Restyle every open terminal when appearance settings change.
    func applyAppearance(_ appearance: TerminalAppearance) {
        for controller in controllers.values {
            controller.apply(appearance)
        }
    }
}
