// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Serializes SSH-thread requests for a single human decision through one
/// SwiftUI sheet, and blocks each requesting thread until its own request is
/// answered.
///
/// Shared by `AgentSignPrompter` and `HostKeyPrompter`: both block a
/// background (SSH) thread while a sheet asks the user something, then return
/// the answer. Sloop allows several terminal sessions at once
/// (`SessionsModel`), so more than one SSH thread can ask the same prompter
/// something around the same moment — two hosts both asking to sign, or two
/// hosts both presenting an unverified key. A single `@Published` slot cannot
/// survive that: a second request arriving before the first is answered would
/// overwrite it, and the first request's `respond` closure would then be
/// unreachable from anywhere — its semaphore would never signal, and that SSH
/// thread would hang forever. This queues concurrent requests and shows them
/// one at a time instead, so a second arrival waits its turn rather than
/// silently destroying the first.
///
/// Generic over `Payload` — the information the sheet needs to show (a key
/// name and endpoint for a sign request; a kind, endpoint, key type and
/// fingerprint for a host-key request) — so each prompter keeps its own
/// `Prompt` type, and therefore its own `@Published var prompt`, which
/// `HostListView`'s `.sheet(item:)` needs. Only the queuing, the blocking
/// handoff, and the fail-closed default are shared; the answer itself is
/// always a plain `Bool` — trust/don't-trust and allow/deny are both, at
/// bottom, one yes-or-no decision.
///
/// Deliberately owns no reference to the prompter it serves, and takes no
/// closure at construction — only a plain, argument-less `init()` exists.
/// Each caller passes its own "how do I reach the user" closure into
/// `request(_:present:)` itself, computed at the call site (inside
/// `shouldSign`/`shouldTrust`, an ordinary instance method where `self` is
/// already a fully-initialized, valid reference). An earlier version of this
/// type instead captured the owning prompter in a closure handed to `init`,
/// stored in a `lazy var` (needed so the closure could reference `self`
/// before `self`'s other stored properties existed). That compiled and
/// usually worked, but `lazy` is not thread-safe: the *first* access to a
/// lazy property races if it happens from two threads at once, and that is
/// exactly what two SSH threads calling into a fresh prompter at the same
/// moment do. Losing that race silently constructed two separate queues, one
/// per thread — each with its own empty `pending` — which reproduced the
/// very bug this type exists to fix, intermittently, only under real
/// concurrency. This shape has no property for that race to hit.
///
/// `request(_:present:)` MUST NOT be called on the main thread: it blocks the
/// calling thread on a semaphore that only the main-queue-confined
/// presentation can signal, so calling it from main would deadlock the app
/// against itself.
final class PromptQueue<Payload> {
    /// Requests waiting their turn, oldest first. Read and mutated only from
    /// blocks already running on the main queue — `enqueue` hops there before
    /// touching it, and so does every completion that follows — so this needs
    /// no lock even though `request` is called concurrently from more than
    /// one SSH thread: the main queue's own serial ordering is what keeps
    /// access to `pending` race-free. A lock would work too, but would
    /// duplicate serialization the main queue already gives for free, for a
    /// property nothing off main ever touches.
    private var pending: [Request] = []

    private struct Request {
        let payload: Payload
        /// How this one request reaches the user — supplied by its caller at
        /// `request(_:present:)` time, not shared queue-wide, so `presentNext`
        /// doesn't need any reference back to whichever prompter enqueued it.
        let present: (Payload, @escaping (Bool) -> Void) -> Void
        let respond: (Bool) -> Void
    }

    /// Called from a background (SSH) thread. Blocks until this specific
    /// request has been answered, and returns exactly that answer.
    func request(_ payload: Payload, present: @escaping (Payload, @escaping (Bool) -> Void) -> Void) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let decision = Decision()
        enqueue(payload, present: present) { allowed in
            // Only an explicit "yes" ever writes to `decision`. Anything else
            // — a refusal, or a bug that fails to answer at all — does not,
            // so it leaves `decision.value` exactly as `Decision` initialized
            // it. That is what makes the fail-closed default load-bearing
            // rather than decorative: it is the thing actually producing
            // "false" on every non-affirmative path, not a redundant copy of
            // an answer that was already computed elsewhere.
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
    /// regardless of which thread called `request`.
    private func enqueue(_ payload: Payload,
                          present: @escaping (Payload, @escaping (Bool) -> Void) -> Void,
                          respond: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let wasEmpty = self.pending.isEmpty
            self.pending.append(Request(payload: payload, present: present, respond: respond))
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
        next.present(next.payload) { allowed in
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

    /// Carries the decision from the main thread (the sheet) back to the
    /// waiting SSH thread; the semaphore provides the happens-before
    /// ordering.
    ///
    /// Defaults to `false`: if anything goes wrong on the way to an answer,
    /// the request is refused. A prompt that fails open would sign or trust
    /// silently, which is the one outcome every caller of this queue exists
    /// to prevent.
    private final class Decision { var value = false }
}
