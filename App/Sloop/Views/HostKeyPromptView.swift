import SwiftUI

/// The host-key confirmation sheet. Handles two cases:
///
/// - **Unknown host** (trust-on-first-use): a neutral "trust this key?" prompt.
/// - **Changed key**: a strong warning — the recorded key no longer matches,
///   which can mean the server was reinstalled *or* a man-in-the-middle attack.
///
/// Both buttons resolve the pending decision, so the blocked SSH thread always
/// continues.
struct HostKeyPromptView: View {
    let prompt: HostKeyPrompter.Prompt

    private var isChanged: Bool {
        if case .changed = prompt.kind { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: isChanged ? "exclamationmark.triangle.fill" : "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(isChanged ? Color.red : Color.accentColor)

            Text(isChanged ? "Host key changed" : "Unknown host")
                .font(.title2.bold())

            Group {
                if isChanged {
                    Text("The key for **\(prompt.endpoint)** is different from the one you previously trusted. This can happen if the server was rebuilt — but it can also mean someone is intercepting the connection. Only accept if you expected this change.")
                } else {
                    Text("The authenticity of **\(prompt.endpoint)** can't be established. Trust this key and continue connecting?")
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                if case .changed(let previous) = prompt.kind {
                    fingerprintRow(label: "Previously trusted", value: previous, strikethrough: true)
                    fingerprintRow(label: "\(prompt.keyType) — new key", value: prompt.fingerprint)
                } else {
                    fingerprintRow(label: prompt.keyType, value: prompt.fingerprint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button(role: .cancel) { prompt.respond(false) } label: {
                    Text(isChanged ? "Cancel" : "Don't Trust").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: isChanged ? .destructive : nil) { prompt.respond(true) } label: {
                    Text(isChanged ? "Accept New Key" : "Trust").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(isChanged ? .red : .accentColor)
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func fingerprintRow(label: String, value: String, strikethrough: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("SHA256:\(value)")
                .font(.system(.footnote, design: .monospaced))
                .strikethrough(strikethrough)
                .foregroundStyle(strikethrough ? Color.secondary : Color.primary)
                .textSelection(.enabled)
        }
    }
}
