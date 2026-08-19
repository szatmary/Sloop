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
/// Mirrors `HostKeyPrompter`: both are thin wrappers around `PromptQueue`,
/// which is where the queuing, the blocking handoff, and the fail-closed
/// default actually live — and `shared` below hands its requests to
/// `PromptQueue.shared`, the SAME queue `HostKeyPrompter.shared` uses, so a
/// sign prompt and a host-key prompt queue behind each other rather than
/// both trying to show at once (see `PromptQueue`'s doc comment). Same rule
/// here as there: the decision method MUST be called off the main thread (it
/// is, from the libssh2 connection thread); calling it on main would
/// deadlock the prompt.
///
/// Blocking the SSH thread means the terminal is unresponsive while the sheet
/// is up. That is the design, not a defect. The alternative is signing without
/// asking, and a signature is precisely what the user is being asked about.
final class AgentSignPrompter: ObservableObject, AgentSignConfirming {
    static let shared = AgentSignPrompter(queue: .shared)

    struct Prompt: Identifiable {
        let id = UUID()
        let keyName: String
        let endpoint: String
        let respond: (Bool) -> Void
    }

    @Published var prompt: Prompt?

    /// How a request reaches the user. Left `nil` in production, where
    /// `shouldSign` falls through to `presentDefault`, which publishes
    /// `prompt` for the sheet; tests inject a closure that stands in for the
    /// sheet and answers synchronously or from a background queue, with no UI
    /// involved.
    private let injectedPresent: ((String, String, @escaping (Bool) -> Void) -> Void)?

    /// Defaults to a fresh, private `PromptQueue()` — not `.shared` — so a
    /// test that doesn't ask for sharing doesn't get it: two unrelated tests
    /// each constructing their own `AgentSignPrompter()` get two independent
    /// queues, exactly as if each still owned its queue outright. `shared`
    /// above is the one production call site that opts into the real
    /// singleton, and a test that wants to prove cross-prompter queuing
    /// passes one `PromptQueue()` instance to two prompters explicitly (see
    /// `CrossPrompterQueueTests`).
    private let queue: PromptQueue

    init(present: ((String, String, @escaping (Bool) -> Void) -> Void)? = nil,
         queue: PromptQueue = PromptQueue()) {
        self.injectedPresent = present
        self.queue = queue
    }

    func shouldSign(keyName: String, endpoint: String) -> Bool {
        queue.request { respond in
            let present = self.injectedPresent ?? self.presentDefault
            present(keyName, endpoint, respond)
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
