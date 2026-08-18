// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit

/// Edits the terminal's appearance (font size, color theme, cursor shape and,
/// on iOS, keyboard style). Bound to the shared `AppearanceStore`, so changes
/// persist and restyle live terminals immediately.
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

                #if os(iOS)
                Section("Keyboard") {
                    Picker("Style", selection: $store.appearance.keyboard) {
                        ForEach(TerminalAppearance.KeyboardStyle.allCases, id: \.self) { style in
                            Text(style.rawValue.capitalized).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Compact is shorter, leaving more of the screen for the terminal. "
                       + "It is US QWERTY only, and has no dictation or emoji — switch back "
                       + "to Standard for those.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #endif
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
