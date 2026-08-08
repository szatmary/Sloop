import Foundation
import SloopKit

/// Persists the terminal `TerminalAppearance` (JSON in `UserDefaults`) and
/// publishes it so views re-render and live terminals restyle when it changes.
/// A shared singleton so the settings editor and every open terminal see one
/// source of truth.
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()

    private static let key = "terminalAppearance"
    private let defaults: UserDefaults

    @Published var appearance: TerminalAppearance {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(TerminalAppearance.self, from: data) {
            appearance = decoded
        } else {
            appearance = .default
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
