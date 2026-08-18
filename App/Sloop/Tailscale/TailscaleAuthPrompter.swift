// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SwiftUI

/// Carries "this device needs authorizing on the tailnet" from the dial to the
/// UI, so the user gets a browser rather than a URL printed in a terminal they
/// can't tap.
///
/// Same shape as `HostKeyPrompter`, and for the same reason: the dial runs on an
/// SSH worker thread with no view in reach, while the thing it needs is a
/// presentation. A singleton the root view observes is the seam between them.
@MainActor
final class TailscaleAuthPrompter: ObservableObject {
    static let shared = TailscaleAuthPrompter()

    /// The device-authorization URL, when one is outstanding. Setting it opens
    /// the sheet; the sheet clears it.
    @Published var url: IdentifiableURL?

    private init() {}

    /// Called from the dial thread.
    nonisolated func request(_ url: URL) {
        Task { @MainActor in
            // Don't stack prompts: reconnecting while the sheet is already up
            // would otherwise replace it with an identical one.
            guard self.url == nil else { return }
            self.url = IdentifiableURL(url: url)
        }
    }
}

/// `sheet(item:)` wants Identifiable, and `URL` isn't.
struct IdentifiableURL: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}
