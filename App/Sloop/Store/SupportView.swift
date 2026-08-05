import SwiftUI

/// The support sheet. Before tipping it invites a one-time tip; after tipping it
/// becomes the Thank-You page with a big heart.
struct SupportView: View {
    @StateObject private var tipJar = TipJar()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if tipJar.hasTipped {
                    thankYou
                } else {
                    invite
                }
            }
            .padding(32)
            .frame(maxWidth: 480)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var thankYou: some View {
        Group {
            Text("❤️").font(.system(size: 88))
            Text("Thank you!").font(.largeTitle.bold())
            Text("Sloop is free and always will be. Your tip keeps it sailing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var invite: some View {
        Group {
            Text("⚓").font(.system(size: 88))
            Text("Support Sloop").font(.largeTitle.bold())
            Text("Sloop is free. If it's useful to you, you can leave a one-time tip to say thanks.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                Task { await tipJar.tip() }
            } label: {
                Text(tipButtonTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(tipJar.product == nil || tipJar.purchasing)

            if tipJar.purchasing {
                ProgressView()
            }
        }
    }

    private var tipButtonTitle: String {
        if let product = tipJar.product {
            return "Leave a tip — \(product.displayPrice)"
        }
        return "Leave a tip"
    }
}
