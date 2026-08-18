// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI

/// The app's visual language, taken from the icon (`App/Sloop/AppIcon.svg`)
/// rather than invented separately — the icon is a white sail and a
/// terminal-teal foresail above a "waterline" made of command-line rules and a
/// cursor block, on a deep teal-to-black ground.
///
/// Two ideas carry through the UI:
///
/// - **Terminal teal** is the single accent. One confident colour used
///   everywhere beats a palette nobody can name.
/// - **The waterline** — a short rule, sometimes with a cursor block — is the
///   recurring motif, standing in for both a horizon and a shell prompt.
///
/// Deliberately small: personality belongs in a few specific places (the mark,
/// the empty state, an accent), not sprinkled across a working terminal.
enum SloopStyle {
    /// The foresail / cursor colour from the icon.
    static let teal = Color(red: 0x4f / 255, green: 0xd1 / 255, blue: 0xc2 / 255)
    /// The deeper teal the icon's gradient settles into, for fills that sit
    /// under text.
    static let deepTeal = Color(red: 0x33 / 255, green: 0xb6 / 255, blue: 0xa7 / 255)
}

/// The icon's waterline: a prompt rule with a cursor block riding on it.
///
/// Small enough to use as a section flourish without turning the UI into a
/// nautical theme park.
struct Waterline: View {
    var width: CGFloat = 120
    var showsCursor: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(SloopStyle.teal.opacity(0.5))
                .frame(width: width, height: 4)
            if showsCursor {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(SloopStyle.teal.opacity(0.85))
                    .frame(width: 8, height: 10)
            }
        }
        .accessibilityHidden(true)
    }
}
