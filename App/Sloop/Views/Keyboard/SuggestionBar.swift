// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if os(iOS)
import SwiftUI

/// A row of completions above the keyboard, drawn from what you've typed on
/// this host before.
///
/// Takes no height when there is nothing to suggest, which is most of the time:
/// a bar that sits there empty costs terminal rows for nothing, and this app
/// spends most of its design budget getting rows back.
///
/// Tapping one sends only the part not yet typed, as keystrokes — the host sees
/// typing, so its own line editing, history and completion behave exactly as if
/// the characters had been tapped out.
struct SuggestionBar: View {
    let suggestions: [String]
    /// What has been typed so far, so the completion can be shown as the
    /// distinct part rather than repeating what's already on screen.
    let typed: String
    let accept: (String) -> Void

    var body: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            accept(suggestion)
                        } label: {
                            label(for: suggestion)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: 38)
            .background(.bar)
        }
    }

    /// The typed prefix dimmed, the completion in full strength — the same
    /// shape fish uses, and it makes the useful part of a long command line
    /// findable at a glance rather than something to read end to end.
    private func label(for suggestion: String) -> some View {
        let completion = suggestion.hasPrefix(typed)
            ? String(suggestion.dropFirst(typed.count))
            : suggestion
        let prefix = suggestion.hasPrefix(typed) ? typed : ""
        return HStack(spacing: 0) {
            Text(prefix).foregroundStyle(.secondary)
            Text(completion).foregroundStyle(.primary)
        }
        .font(.system(.footnote, design: .monospaced))
        .lineLimit(1)
    }
}
#endif
