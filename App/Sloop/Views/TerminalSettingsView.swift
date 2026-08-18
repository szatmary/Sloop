// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit

/// Edits the terminal's appearance (font size, color theme, cursor shape and,
/// on iOS, keyboard style). Bound to the shared `AppearanceStore`, so changes
/// persist and restyle live terminals immediately.
struct TerminalSettingsView: View {
    /// Set when the user asks to clear history, so the confirmation can be
    /// answered before anything is deleted.
    @State private var clearingHistory = false
    @State private var clearingFailed: String?

    @ObservedObject var store: AppearanceStore
    @Environment(\.dismiss) private var dismiss

    /// Delete every host's history. Reported rather than swallowed: someone
    /// clearing this is making a decision about what is stored on their device,
    /// and "done" when it isn't would be the worst possible answer.
    private func clearHistory() {
        do {
            try CommandHistoryStore().forgetEverything()
        } catch {
            clearingFailed = error.localizedDescription
        }
    }

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

                Section("Suggestions") {
                    Text("""
                    As you type, Sloop offers the word that usually comes next — \
                    learnt from the commands you run on a host, and from that \
                    host's own shell history, which it reads once when you \
                    connect. Each host decides for itself, in its own settings \
                    beside Use Mosh.
                    """)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Label("""
                    What Sloop learns stays on this device. It isn't synced to \
                    iCloud, it isn't shared with your other devices, and it is \
                    never sent to a server or to anyone else. There's no account \
                    and nothing to opt out of, because there is nowhere for it \
                    to go. A host with suggestions switched off is not recorded \
                    at all.
                    """, systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        clearingHistory = true
                    } label: {
                        Text("Clear Command History")
                    }
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
            .confirmationDialog("Clear command history?",
                                isPresented: $clearingHistory, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { clearHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes everything Sloop has learned about the commands you run, "
                   + "on every host. Suggestions start again from your hosts' own shell "
                   + "history the next time you connect.")
            }
            .alert("Couldn't Clear History", isPresented: Binding(
                get: { clearingFailed != nil },
                set: { if !$0 { clearingFailed = nil } })
            ) {
                Button("OK", role: .cancel) { clearingFailed = nil }
            } message: {
                Text(clearingFailed ?? "")
            }
        }
    }
}
