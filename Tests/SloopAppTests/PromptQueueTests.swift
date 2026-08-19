// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS
@testable import SloopSSH

/// `presentNext` hands each request's answer back through a closure the
/// presenting view calls to resolve it — `Prompt.respond` in both
/// `AgentSignPromptView` and `HostKeyPromptView`, wired straight through to
/// this queue's own per-request completion, unmodified. A bare SwiftUI
/// `Button` action gives no protection against that closure firing twice (a
/// double-tap, or Escape landing mid-dismiss).
///
/// These tests drive that exact trigger directly through the `present:`
/// closure `PromptQueue.request` hands its caller — calling it twice here IS
/// calling `prompt.respond` twice from a view, without needing SwiftUI or a
/// real sheet to reproduce the double-tap.
final class PromptQueueTests: XCTestCase {

    /// Reproduces the reviewer's probe verbatim: a lone request, answered
    /// twice. Unfixed, the second answer runs `pending.removeFirst()` on an
    /// already-empty array and traps the process — "Fatal error: Can't
    /// remove first element from an empty collection" — so this doesn't fail
    /// cleanly pre-fix, it crashes the test run. Fixed, the second call is a
    /// no-op: the first answer still reaches the caller, and the queue is
    /// left in exactly the state the first call already left it — provable
    /// by handing it a second, independent request afterward and confirming
    /// that one is served normally too.
    func testDoubleRespondOnSoleRequestDoesNotCrash() {
        let queue = PromptQueue()
        let answered = expectation(description: "request answered")
        var result: Bool?

        DispatchQueue.global().async {
            result = queue.request { respond in
                respond(true)
                respond(true)   // the double-tap
            }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)

        XCTAssertEqual(result, true, "the one genuine answer must still reach the caller")

        // Not merely "didn't crash" — the queue must still be able to serve
        // a later, unrelated request, proving `pending` wasn't left corrupt
        // or the presentation loop wasn't left stuck.
        let secondAnswered = expectation(description: "later request answered")
        var secondResult: Bool?
        DispatchQueue.global().async {
            secondResult = queue.request { respond in respond(false) }
            secondAnswered.fulfill()
        }
        wait(for: [secondAnswered], timeout: 2)
        XCTAssertEqual(secondResult, false, "the queue must still serve later requests after a double respond")
    }

    /// The worse of the two failures the reviewer found: with a second
    /// request already queued behind the first, a double respond on the
    /// first must not disturb the second. Unfixed, the first tap's own
    /// `presentNext` completion runs, correctly removing the first request
    /// and presenting the second; the second (bogus) tap then runs the SAME
    /// completion again, and its `pending.removeFirst()` — with no request
    /// of its own left to remove — instead removes the second request,
    /// which is still legitimately sitting at the front, mid-presentation.
    /// Whether that manifests as the second request's own eventual answer
    /// hitting an already-empty `pending` (a crash, reproduced verbatim
    /// below, since this test's second request answers itself right away)
    /// or as a hang (if something else were queued behind it to silently
    /// absorb the bogus removal instead) depends only on timing — the
    /// defect is the extra `removeFirst()`, not which symptom it happens to
    /// produce. Fixed, the second request is presented and answered on its
    /// own, independent of the first's double-tap.
    func testDoubleRespondOnFirstRequestLeavesSecondPresentedAndAnswerable() {
        let queue = PromptQueue()

        let firstPresented = expectation(description: "first request presented")
        let secondPresented = expectation(description: "second request presented")
        let firstAnswered = expectation(description: "first request answered")
        let secondAnswered = expectation(description: "second request answered")

        var firstRespond: ((Bool) -> Void)?
        var firstResult: Bool?
        var secondResult: Bool?

        DispatchQueue.global().async {
            firstResult = queue.request { respond in
                // Captured, not called yet: `present` runs synchronously on
                // the main queue (from `presentNext`), so blocking here —
                // with `Thread.sleep` or a same-thread `.sync` — would block
                // the very main queue the second request needs in order to
                // enqueue at all. Holding the answer open and returning
                // immediately is what lets the second request actually land
                // behind this one before this test answers.
                firstRespond = respond
                firstPresented.fulfill()
            }
            firstAnswered.fulfill()
        }

        wait(for: [firstPresented], timeout: 2)

        DispatchQueue.global().async {
            secondResult = queue.request { respond in
                secondPresented.fulfill()
                respond(false)
            }
            secondAnswered.fulfill()
        }

        // Pump the run loop for a fixed window before answering, so the
        // second request's `enqueue` — submitted from its own background
        // thread — has landed on `pending` first. An always-unfulfilled
        // expectation is used purely as a run-loop-pumping delay: unlike
        // `Thread.sleep`, `wait(for:timeout:)` keeps servicing
        // `DispatchQueue.main` while it waits, which is what `enqueue` needs
        // in order to run at all.
        let secondHadTimeToEnqueue = expectation(description: "second request had time to enqueue")
        secondHadTimeToEnqueue.isInverted = true
        wait(for: [secondHadTimeToEnqueue], timeout: 0.5)

        firstRespond?(true)
        firstRespond?(true)   // the double-tap

        // Bounded waits throughout: pre-fix, the second request's thread
        // hangs forever, which must show up here as a timeout failure, not
        // an indefinitely blocked test run.
        wait(for: [secondPresented, firstAnswered, secondAnswered], timeout: 3)

        XCTAssertEqual(firstResult, true, "the first request's own genuine answer must still reach it")
        XCTAssertEqual(secondResult, false,
                        "the second request must be presented and answered on its own, not dropped by the first's double respond")
    }

    /// `request`'s semaphore is private and scoped to a single call, so
    /// nothing outside `PromptQueue` can read its count directly. What a
    /// black-box test CAN show is the property that count exists to
    /// guarantee: `presentNext`'s per-request completion writes the decision
    /// and signals the semaphore in the same guarded step (see
    /// `PromptQueue.presentNext`), so if a second `respond` call is proven to
    /// have zero effect on the decision, it never reached the signal either
    /// — the two are not separately reachable. Answering `true` then `false`
    /// (not two equal calls) rules out the second call happening to agree by
    /// coincidence; only "the second call never ran" explains the result
    /// staying `true`. That is what "signalled exactly once" means for a
    /// caller: the first answer is the only one that counts, full stop —
    /// a second signal on top of it is exactly what would let some later,
    /// unrelated `wait()` fall through without a real answer behind it.
    func testSecondRespondCallHasNoEffectOnTheDecision() {
        let queue = PromptQueue()
        let answered = expectation(description: "answered")
        var result: Bool?

        DispatchQueue.global().async {
            result = queue.request { respond in
                respond(true)
                respond(false)   // must be fully inert, not just "harmless"
            }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)

        XCTAssertEqual(result, true, "only the first respond call may affect the decision or signal the semaphore")
    }
}
