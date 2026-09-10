# Tip jar (support IAP)

Sloop is free. The only in-app purchase is a **non-consumable "Leave a Tip"**
whose sole effect is to unlock a Thank-You page with a ❤️ — no features are
gated behind it.

## Pieces

- `App/Sloop/Store/TipJar.swift` — StoreKit 2 store: loads the product, restores
  the entitlement, listens for `Transaction.updates`, and runs the purchase.
- `App/Sloop/Store/SupportView.swift` — the sheet: an invite-to-tip state and,
  once purchased, the Thank-You page.
- Entry point: a **heart** button in the host-list toolbar opens `SupportView`.
- `App/Sloop/Sloop.storekit` — a StoreKit configuration for testing the purchase
  in the simulator without App Store Connect.

## Product

| Field | Value |
| --- | --- |
| Product ID | `org.szatmary.sloop.tip` |
| Type | Non-consumable |
| Price | set in App Store Connect (the `.storekit` file uses 1.99 for local testing) |

## To ship it

1. Create the non-consumable `org.szatmary.sloop.tip` in App Store Connect and
   set the price.
2. Add the **In-App Purchase** capability to the app target.
3. For simulator/Xcode testing, set the scheme's *StoreKit Configuration* to
   `App/Sloop/Sloop.storekit` (Scheme → Run → Options).

## Ideas for later

- Multiple tip tiers (small/medium/large) — switch to consumables and let people
  tip more than once.
- A subtle "❤️ tipped" marker somewhere once purchased.
