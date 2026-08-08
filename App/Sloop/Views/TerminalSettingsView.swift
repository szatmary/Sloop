import SwiftUI
import SloopKit

/// Edits the terminal's appearance (font size, color theme, cursor shape). Bound
/// to the shared `AppearanceStore`, so changes persist and restyle live
/// terminals immediately.
struct TerminalSettingsView: View {
    @ObservedObject var store: AppearanceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Font") {
                    Stepper(
                        value: $store.appearance.fontSize,
                        in: TerminalAppearance.fontSizeRange,
                        step: 1
                    ) {
                        Text("Size: \(Int(store.appearance.fontSize)) pt")
                    }
                }

                Section("Theme") {
                    Picker("Colors", selection: $store.appearance.theme) {
                        ForEach(TerminalAppearance.Theme.allCases, id: \.self) { theme in
                            Text(theme.rawValue.capitalized).tag(theme)
                        }
                    }
                }

                Section("Cursor") {
                    Picker("Shape", selection: $store.appearance.cursor) {
                        ForEach(TerminalAppearance.CursorStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Terminal")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
