// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI
import SloopKit

/// An interactive `HostKeyVerifier`. When the SSH loop meets an unknown host key
/// — or a *changed* key for a known host — it blocks that background thread
/// while a SwiftUI sheet asks the user what to do, then returns their decision.
///
/// A single shared instance is observed by the UI and injected into new SSH
/// transports, so any connection's prompt surfaces over the app.
///
/// Mirrors `AgentSignPrompter`: both are thin wrappers around `PromptQueue` —
/// and `shared` below hands its requests to `PromptQueue.shared`, the SAME
/// queue `AgentSignPrompter.shared` uses, so a host-key prompt and a sign
/// prompt queue behind each other rather than both trying to show at once
/// (see `PromptQueue`'s doc comment for why that sharing matters: `HostListView`
/// presents both prompters on the same view, and SwiftUI can only show one
/// sheet from one view at a time).
///
/// The decision methods MUST be called off the main thread (they are — from the
/// libssh2 connection thread); calling them on main would deadlock the prompt.
final class HostKeyPrompter: ObservableObject, HostKeyVerifier {
    static let shared = HostKeyPrompter(queue: .shared)

    /// Why we're prompting: a first-time key (trust-on-first-use) or a key that
    /// changed from what we had on record (a possible MITM — a stronger warning).
    enum Kind {
        case unknown
        case changed(previousFingerprint: String)
    }

    struct Prompt: Identifiable {
        let id = UUID()
        let kind: Kind
        let endpoint: String
        let keyType: String
        let fingerprint: String
        let respond: (Bool) -> Void
    }

    @Published var prompt: Prompt?

    /// How a request reaches the user. Left `nil` in production, where `ask`
    /// falls through to `presentDefault`, which publishes `prompt` for the
    /// sheet; tests inject a closure that stands in for the sheet and answers
    /// synchronously or from a background queue, with no UI involved —
    /// mirrors `AgentSignPrompter`'s `present:` seam.
    private let injectedPresent: ((Kind, String, String, String, @escaping (Bool) -> Void) -> Void)?

    /// Defaults to a fresh, private `PromptQueue()` — see
    /// `AgentSignPrompter.queue`'s doc comment for why: `shared` below is the
    /// one production call site that opts into the real singleton, so
    /// unrelated tests each constructing their own `HostKeyPrompter()` stay
    /// isolated from each other by default.
    private let queue: PromptQueue

    init(present: ((Kind, String, String, String, @escaping (Bool) -> Void) -> Void)? = nil,
         queue: PromptQueue = PromptQueue()) {
        self.injectedPresent = present
        self.queue = queue
    }

    func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool {
        ask(kind: .unknown, endpoint: endpoint, keyType: keyType, fingerprint: fingerprint)
    }

    func shouldTrustChangedKey(endpoint: String,
                               keyType: String,
                               fingerprint: String,
                               previousFingerprint: String) -> Bool {
        ask(kind: .changed(previousFingerprint: previousFingerprint),
            endpoint: endpoint, keyType: keyType, fingerprint: fingerprint)
    }

    private func ask(kind: Kind, endpoint: String, keyType: String, fingerprint: String) -> Bool {
        queue.request { respond in
            let present = self.injectedPresent ?? self.presentDefault
            present(kind, endpoint, keyType, fingerprint, respond)
        }
    }

    /// Publishes the current request for the sheet to pick up, and clears it
    /// again once the user has answered. Only ever called by `queue`'s
    /// `presentNext`, so always on the main queue and always for one request
    /// at a time.
    private func presentDefault(kind: Kind,
                                 endpoint: String,
                                 keyType: String,
                                 fingerprint: String,
                                 respond: @escaping (Bool) -> Void) {
        self.prompt = Prompt(kind: kind, endpoint: endpoint, keyType: keyType, fingerprint: fingerprint) { trusted in
            respond(trusted)
            self.prompt = nil
        }
    }
}
