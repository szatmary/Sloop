import SwiftUI

/// The "unknown host key" confirmation sheet. Both buttons resolve the pending
/// decision, so the blocked SSH thread always continues.
struct HostKeyPromptView: View {
    let prompt: HostKeyPrompter.Prompt

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            Text("Unknown host")
                .font(.title2.bold())

            Text("The authenticity of **\(prompt.endpoint)** can't be established. Trust this key and continue connecting?")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(prompt.keyType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("SHA256:\(prompt.fingerprint)")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button(role: .cancel) { prompt.respond(false) } label: {
                    Text("Don't Trust").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { prompt.respond(true) } label: {
                    Text("Trust").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .interactiveDismissDisabled()
    }
}
