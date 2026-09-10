// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI

/// The forwarded-agent signing confirmation sheet.
///
/// Shown every time a remote host asks Sloop's forwarded agent to sign
/// something — which key, and on whose behalf. Deny is the default action:
/// dismissing without an explicit choice, or tapping the wrong thing in a
/// hurry, must not authenticate the user somewhere else.
struct AgentSignPromptView: View {
    let prompt: AgentSignPrompter.Prompt

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "signature")
                .font(.system(size: 52))
                .foregroundStyle(SloopStyle.teal)

            Text("Allow signature request?")
                .font(.title2.bold())

            Text("**\(prompt.endpoint)** is asking to sign with your key **\(prompt.keyName)**. Allowing this lets that host authenticate as you somewhere else — anywhere this key is trusted — for as long as this connection stays open.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(prompt.keyName)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button(role: .cancel) { prompt.respond(false) } label: {
                    Text("Deny").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { prompt.respond(true) } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SloopStyle.teal)
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .interactiveDismissDisabled()
    }
}
