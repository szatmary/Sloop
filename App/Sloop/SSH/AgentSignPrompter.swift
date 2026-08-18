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
///
/// Sloop allows several terminal sessions at once (`SessionsModel`), so more
/// than one SSH thread can call `shouldSign` on this same shared instance
/// around the same moment — two hosts both asking to sign. There is only one
/// sheet, so concurrent requests are queued and shown one at a time
/// (`pending`/`presentNext`) rather than one silently overwriting another's
/// slot: a dropped *dialog* would just be a UX bug, but a dropped *request*
/// here means the SSH thread that made it hangs forever, because nothing else
/// holds a reference to its `respond` closure once the sheet has moved on.
final class AgentSignPrompter: ObservableObject, AgentSignConfirming {
    static let shared = AgentSignPrompter()

    struct Prompt: Identifiable {
        let id = UUID()
        let keyName: String
        let endpoint: String
        let respond: (Bool) -> Void
    }

    @Published var prompt: Prompt?

    /// How the request currently at the front of the queue reaches the user.
    /// Left `nil` in production, where `presentNext` falls through to
    /// `presentDefault`, which publishes `prompt` for the sheet; tests inject
    /// a closure that stands in for the sheet and answers synchronously or
    /// from a background queue, with no UI involved. Either way, `presentNext`
    /// only ever calls this for one request at a time, so this closure itself
    /// doesn't need to know anything about queuing.
    private let injectedPresent: ((String, String, @escaping (Bool) -> Void) -> Void)?

    /// Sign requests waiting their turn, oldest first. Read and mutated only
    /// from blocks already running on the main queue — `enqueue` hops there
    /// before touching it, and so does every completion that follows — so
    /// this needs no lock even though `shouldSign` is called concurrently
    /// from more than one SSH thread: the main queue's own serial ordering is
    /// what keeps access to `pending` race-free. A lock would work too, but
    /// would duplicate serialization the main queue already gives for free,
    /// for a property nothing off main ever touches.
    private var pending: [Request] = []

    private struct Request {
        let keyName: String
        let endpoint: String
        let respond: (Bool) -> Void
    }

    init(present: ((String, String, @escaping (Bool) -> Void) -> Void)? = nil) {
        self.injectedPresent = present
    }

    func shouldSign(keyName: String, endpoint: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let decision = Decision()
        enqueue(keyName: keyName, endpoint: endpoint) { allowed in
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

    /// Adds a request to the queue, and shows it immediately if nothing else
    /// is currently showing. Always hops to the main queue first, so whether
    /// the queue "was empty" — and therefore whether this request should be
    /// presented right away — is decided serially with every other request's,
    /// regardless of which SSH thread called `shouldSign`.
    private func enqueue(keyName: String, endpoint: String, respond: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let wasEmpty = self.pending.isEmpty
            self.pending.append(Request(keyName: keyName, endpoint: endpoint, respond: respond))
            if wasEmpty {
                self.presentNext()
            }
        }
    }

    /// Shows the request at the front of the queue, if there is one. Called
    /// only on the main queue: once from `enqueue`, when a request arrived
    /// with nothing else pending, and once more after each request is
    /// answered, to move on to whatever arrived behind it.
    private func presentNext() {
        guard let next = pending.first else { return }
        let present = injectedPresent ?? presentDefault
        present(next.keyName, next.endpoint) { allowed in
            DispatchQueue.main.async {
                // Nothing removes an entry from `pending` before its own
                // answer arrives, and nothing but `enqueue` appends to it, so
                // the request we just answered is still the one at the front.
                self.pending.removeFirst()
                next.respond(allowed)
                self.presentNext()
            }
        }
    }

    /// Publishes the current request for the sheet to pick up, and clears it
    /// again once the user has answered. Only ever called by `presentNext`,
    /// so always on the main queue and always for one request at a time.
    private func presentDefault(keyName: String, endpoint: String, respond: @escaping (Bool) -> Void) {
        self.prompt = Prompt(keyName: keyName, endpoint: endpoint) { allowed in
            respond(allowed)
            self.prompt = nil
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
