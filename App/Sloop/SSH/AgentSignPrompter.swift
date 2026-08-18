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
/// Mirrors `HostKeyPrompter` — same shared instance observed by the UI, same
/// semaphore handoff, same rule: the decision method MUST be called off the
/// main thread (it is, from the libssh2 connection thread); calling it on main
/// would deadlock the prompt.
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

    /// How tests reach the prompt: a closure that stands in for the sheet and
    /// answers synchronously or from a background queue, with no UI involved.
    /// Left `nil` in production, where `shouldSign` falls through to
    /// `presentDefault` instead.
    private let injectedPresent: ((String, String, @escaping (Bool) -> Void) -> Void)?

    init(present: ((String, String, @escaping (Bool) -> Void) -> Void)? = nil) {
        self.injectedPresent = present
    }

    func shouldSign(keyName: String, endpoint: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let decision = Decision()
        let present = injectedPresent ?? presentDefault
        present(keyName, endpoint) { allowed in
            // Only an explicit "allow" ever writes to `decision`. A refusal
            // does not — it leaves `decision.value` exactly as `Decision`
            // initialized it, so the fail-closed default is the thing
            // actually producing "false" here, not a redundant copy of it.
            // That is what makes the default load-bearing rather than
            // decorative, and it's why flipping it is expected to break
            // `testRefusalIsReportedAsRefusal`.
            if allowed { decision.value = true }
            semaphore.signal()
        }
        semaphore.wait()
        return decision.value
    }

    /// Publishes the prompt on the main thread for the sheet to pick up, and
    /// clears it again once the user has answered.
    private func presentDefault(keyName: String, endpoint: String, respond: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.prompt = Prompt(keyName: keyName, endpoint: endpoint) { allowed in
                respond(allowed)
                self.prompt = nil
            }
        }
    }

    /// Carries the decision from the main thread (the sheet) back to the
    /// waiting SSH thread; the semaphore provides the happens-before ordering.
    ///
    /// Defaults to `false`: if anything goes wrong on the way to an answer,
    /// the request is refused. A prompt that fails open would sign silently,
    /// which is the one outcome this whole task exists to prevent.
    private final class Decision { var value = false }
}
