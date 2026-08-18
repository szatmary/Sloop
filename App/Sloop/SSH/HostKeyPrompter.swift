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
/// Mirrors `AgentSignPrompter`: both are thin wrappers around the shared
/// `PromptQueue`, needed for the same reason — Sloop allows several terminal
/// sessions at once (`SessionsModel`), so more than one SSH thread can ask
/// this same shared instance to verify a host key around the same moment,
/// e.g. two hosts with unknown keys connecting together. `PromptQueue` is
/// what stops a second such request from silently overwriting the first's
/// `respond` closure and hanging its SSH thread forever, which is exactly
/// what a single `@Published` slot with no queue would do.
///
/// The decision methods MUST be called off the main thread (they are — from the
/// libssh2 connection thread); calling them on main would deadlock the prompt.
final class HostKeyPrompter: ObservableObject, HostKeyVerifier {
    static let shared = HostKeyPrompter()

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

    private struct Payload {
        let kind: Kind
        let endpoint: String
        let keyType: String
        let fingerprint: String
    }

    /// How a request reaches the user. Left `nil` in production, where `ask`
    /// falls through to `presentDefault`, which publishes `prompt` for the
    /// sheet; tests inject a closure that stands in for the sheet and answers
    /// synchronously or from a background queue, with no UI involved —
    /// mirrors `AgentSignPrompter`'s `present:` seam.
    private let injectedPresent: ((Kind, String, String, String, @escaping (Bool) -> Void) -> Void)?

    /// Plain, eagerly-initialized — see `PromptQueue`'s doc comment for why
    /// it takes no closure at construction and therefore needs no `lazy`.
    private let queue = PromptQueue<Payload>()

    init(present: ((Kind, String, String, String, @escaping (Bool) -> Void) -> Void)? = nil) {
        self.injectedPresent = present
    }

    func shouldTrust(endpoint: String, keyType: String, fingerprint: String) -> Bool {
        ask(Payload(kind: .unknown, endpoint: endpoint, keyType: keyType, fingerprint: fingerprint))
    }

    func shouldTrustChangedKey(endpoint: String,
                               keyType: String,
                               fingerprint: String,
                               previousFingerprint: String) -> Bool {
        ask(Payload(kind: .changed(previousFingerprint: previousFingerprint),
                    endpoint: endpoint, keyType: keyType, fingerprint: fingerprint))
    }

    private func ask(_ payload: Payload) -> Bool {
        queue.request(payload) { payload, respond in
            let present = self.injectedPresent ?? self.presentDefault
            present(payload.kind, payload.endpoint, payload.keyType, payload.fingerprint, respond)
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
