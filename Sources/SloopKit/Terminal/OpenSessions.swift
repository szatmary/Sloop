import Foundation

/// The set of terminal sessions the user has open, plus which one is active —
/// the model behind a tab bar / session switcher.
///
/// Pure value type with no UIKit/AppKit dependency, so the open/select/close
/// logic (including which tab becomes active when the active one closes) is
/// unit-tested in SloopKit. The app layer wraps it in an `ObservableObject`.
public struct OpenSessions {
    public private(set) var sessions: [TerminalSession]
    public private(set) var selectedID: TerminalSession.ID?

    public init(sessions: [TerminalSession] = []) {
        self.sessions = sessions
        self.selectedID = sessions.last?.id
    }

    public var selected: TerminalSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    public var isEmpty: Bool { sessions.isEmpty }
    public var count: Int { sessions.count }

    /// Open a session and make it the active one.
    public mutating func open(_ session: TerminalSession) {
        sessions.append(session)
        selectedID = session.id
    }

    /// Make an already-open session active. No-op if the id isn't open.
    public mutating func select(_ id: TerminalSession.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Move selection to the next tab, wrapping past the end. No-op if empty;
    /// selects the first tab if nothing was selected.
    public mutating func selectNext() {
        guard !sessions.isEmpty else { return }
        guard let id = selectedID,
              let i = sessions.firstIndex(where: { $0.id == id }) else {
            selectedID = sessions.first?.id
            return
        }
        selectedID = sessions[(i + 1) % sessions.count].id
    }

    /// Move selection to the previous tab, wrapping past the start. No-op if
    /// empty; selects the last tab if nothing was selected.
    public mutating func selectPrevious() {
        guard !sessions.isEmpty else { return }
        guard let id = selectedID,
              let i = sessions.firstIndex(where: { $0.id == id }) else {
            selectedID = sessions.last?.id
            return
        }
        selectedID = sessions[(i - 1 + sessions.count) % sessions.count].id
    }

    /// Close a session. When the active session closes, selection moves to the
    /// tab on its left (or the first remaining), or becomes `nil` if none are
    /// left. Returns the removed session, or `nil` if the id wasn't open.
    @discardableResult
    public mutating func close(_ id: TerminalSession.ID) -> TerminalSession? {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = sessions.remove(at: index)
        if selectedID == id {
            if sessions.isEmpty {
                selectedID = nil
            } else {
                let neighbor = max(0, index - 1)
                selectedID = sessions[min(neighbor, sessions.count - 1)].id
            }
        }
        return removed
    }
}
