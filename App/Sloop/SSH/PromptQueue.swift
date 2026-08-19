// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Serializes SSH-thread requests for a single human decision through one
/// SwiftUI sheet, and blocks each requesting thread until its own request is
/// answered.
///
/// Shared by `AgentSignPrompter` and `HostKeyPrompter` — not just in the
/// sense that both are built on this type, but literally: `AgentSignPrompter
/// .shared` and `HostKeyPrompter.shared` both hand their requests to the same
/// `PromptQueue.shared` instance. That sharing is load-bearing, not
/// incidental. `HostListView` presents both prompters' `prompt` through their
/// own `.sheet(item:)` modifier, on the same view. A host-key prompt (session
/// A connecting to a new host) and a sign prompt (session B's forwarded agent
/// asked to sign) can each be triggered from a different SSH thread around
/// the same moment — two ordinary sessions doing two ordinary things, not a
/// contrived scenario. If each prompter queued only its own requests,
/// nothing would stop both `@Published var prompt`s from going non-nil
/// together, and SwiftUI can only actually present one sheet from one view
/// at a time — the second `.sheet`'s content is never shown, so nothing ever
/// calls its `respond`, and that SSH thread hangs forever. Routing every
/// prompt of every kind through one queue is what makes "at most one prompt
/// is ever live, of either kind" true, the same way a single prompter's own
/// queue makes "at most one prompt of THAT kind is ever live" true.
///
/// Deliberately not generic over a payload type, unlike an earlier version
/// of this file. Making each prompter instantiate its own
/// `PromptQueue<ItsOwnPayloadType>` is exactly what made sharing one queue
/// between the two prompter *types* impossible without inventing a union
/// payload type to force them onto the same generic instantiation.
/// Dropping the type parameter removes the need: `request(present:)` takes a
/// single `(@escaping (Bool) -> Void) -> Void` closure, and that closure
/// already captures whatever its caller needs (a key name and endpoint; a
/// kind, endpoint, key type and fingerprint) from its own enclosing scope,
/// the ordinary way a closure captures anything — the generic parameter was
/// only ever a payload `PromptQueue` itself forwarded without inspecting,
/// so threading it through was ceremony, not function.
///
/// `request(present:)` MUST NOT be called on the main thread: it blocks the
/// calling thread on a semaphore that only the main-queue-confined
/// presentation can signal, so calling it from main would deadlock the app
/// against itself.
final class PromptQueue {
    /// The instance `AgentSignPrompter.shared` and `HostKeyPrompter.shared`
    /// both hand their requests to, so a sign prompt and a host-key prompt
    /// queue behind each other instead of colliding on `HostListView`'s two
    /// `.sheet(item:)` modifiers. Tests construct their own `PromptQueue()`
    /// instead of using this — a fresh, private instance per prompter (the
    /// default, see below) keeps unrelated tests from leaking state into
    /// each other through this singleton; a *shared* fresh instance, handed
    /// explicitly to two prompter instances, is how a test proves
    /// cross-prompter queuing specifically.
    static let shared = PromptQueue()

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
        /// How this one request reaches the user — supplied by its caller at
        /// `request(present:)` time, already carrying whatever it needs to
        /// show via ordinary closure capture, so `presentNext` doesn't need
        /// any reference back to whichever prompter enqueued it.
        let present: (@escaping (Bool) -> Void) -> Void
        let respond: (Bool) -> Void
    }

    /// Called from a background (SSH) thread. Blocks until this specific
    /// request has been answered, and returns exactly that answer.
    func request(present: @escaping (@escaping (Bool) -> Void) -> Void) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let decision = Decision()
        enqueue(present: present) { allowed in
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
    /// is currently showing — of either kind, since every prompter sharing
    /// this queue funnels through the same `pending`. Always hops to the
    /// main queue first, so whether the queue "was empty" — and therefore
    /// whether this request should be presented right away — is decided
    /// serially with every other request's, regardless of which thread, or
    /// which prompter, called `request`.
    private func enqueue(present: @escaping (@escaping (Bool) -> Void) -> Void,
                          respond: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let wasEmpty = self.pending.isEmpty
            self.pending.append(Request(present: present, respond: respond))
            if wasEmpty {
                self.presentNext()
            }
        }
    }

    /// Shows the request at the front of the queue, if there is one. Called
    /// only on the main queue: once from `enqueue`, when a request arrived
    /// with nothing else pending, and once more after each request is
    /// answered, to move on to whatever arrived behind it — possibly from a
    /// different prompter than the one that was just showing.
    private func presentNext() {
        guard let next = pending.first else { return }
        next.present { allowed in
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
