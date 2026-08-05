import StoreKit
import SwiftUI

/// A one-time "Leave a Tip" purchase. Sloop is free; this non-consumable IAP is
/// pure support — buying it unlocks the Thank-You page (❤️) and nothing else.
@MainActor
final class TipJar: ObservableObject {
    /// Configure this non-consumable product in App Store Connect (and in
    /// Sloop.storekit for local testing).
    static let tipProductID = "org.szatmary.sloop.tip"

    @Published private(set) var product: Product?
    @Published private(set) var hasTipped = false
    @Published private(set) var purchasing = false

    init() {
        Task { await start() }
    }

    /// Load the product, restore any existing entitlement, then keep listening
    /// for transaction updates (e.g. a purchase made on another device).
    private func start() async {
        await loadProduct()
        await refreshEntitlement()
        for await update in Transaction.updates {
            if case .verified(let transaction) = update {
                if transaction.productID == Self.tipProductID { hasTipped = true }
                await transaction.finish()
            }
        }
    }

    func loadProduct() async {
        product = try? await Product.products(for: [Self.tipProductID]).first
    }

    /// Has the user already tipped? Non-consumables stay in current entitlements.
    func refreshEntitlement() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.tipProductID {
                hasTipped = true
            }
        }
    }

    func tip() async {
        guard let product, !purchasing else { return }
        purchasing = true
        defer { purchasing = false }

        guard let result = try? await product.purchase() else { return }
        if case .success(.verified(let transaction)) = result {
            hasTipped = true
            await transaction.finish()
        }
    }
}
