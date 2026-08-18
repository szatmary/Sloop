// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import SwiftUI

/// Asks the user whether a forwarded agent may sign with a given key.
protocol AgentSignConfirming {
    /// Called on the SSH thread. Blocks until the user answers.
    func shouldSign(keyName: String, endpoint: String) -> Bool
}

/// An interactive `AgentSignConfirming`. When a forwarded agent is asked to
/// sign, it blocks the SSH thread while a SwiftUI sheet names the key and the
/// host, then returns the user's decision.
///
/// Mirrors `HostKeyPrompter`: both are thin wrappers around the shared
/// `PromptQueue`, which is where the queuing, the blocking handoff, and the
/// fail-closed default actually live. Same rule here as there: the decision
/// method MUST be called off the main thread (it is, from the libssh2
/// connection thread); calling it on main would deadlock the prompt.
///
/// Blocking the SSH thread means the terminal is unresponsive while the sheet
/// is up. That is the design, not a defect. The alternative is signing without
/// asking, and a signature is precisely what the user is being asked about.
final class AgentSignPrompter: ObservableObject, AgentSignConfirming {
    static let shared = AgentSignPrompter()

    struct Prompt: Identifiable {
        let id = UUID()
        let keyName: String
        let endpoint: String
        let respond: (Bool) -> Void
    }

    @Published var prompt: Prompt?

    private struct Payload {
        let keyName: String
        let endpoint: String
    }

    /// How a request reaches the user. Left `nil` in production, where
    /// `shouldSign` falls through to `presentDefault`, which publishes
    /// `prompt` for the sheet; tests inject a closure that stands in for the
    /// sheet and answers synchronously or from a background queue, with no UI
    /// involved.
    private let injectedPresent: ((String, String, @escaping (Bool) -> Void) -> Void)?

    /// Plain, eagerly-initialized — see `PromptQueue`'s doc comment for why
    /// it takes no closure at construction and therefore needs no `lazy`.
    private let queue = PromptQueue<Payload>()

    init(present: ((String, String, @escaping (Bool) -> Void) -> Void)? = nil) {
        self.injectedPresent = present
    }

    func shouldSign(keyName: String, endpoint: String) -> Bool {
        queue.request(Payload(keyName: keyName, endpoint: endpoint)) { payload, respond in
            let present = self.injectedPresent ?? self.presentDefault
            present(payload.keyName, payload.endpoint, respond)
        }
    }

    /// Publishes the current request for the sheet to pick up, and clears it
    /// again once the user has answered. Only ever called by `queue`'s
    /// `presentNext`, so always on the main queue and always for one request
    /// at a time.
    private func presentDefault(keyName: String, endpoint: String, respond: @escaping (Bool) -> Void) {
        self.prompt = Prompt(keyName: keyName, endpoint: endpoint) { allowed in
            respond(allowed)
            self.prompt = nil
        }
    }
}
