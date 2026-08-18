// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Combine
import XCTest
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS

final class AgentSignPrompterTests: XCTestCase {
    /// The SSH thread must not proceed until the user has answered, and must
    /// see the answer they gave. This is the whole point of the type.
    func testBlocksTheCallingThreadUntilAnswered() {
        let prompter = AgentSignPrompter(present: { _, _, respond in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { respond(true) }
        })

        let answered = expectation(description: "answered")
        DispatchQueue.global().async {
            XCTAssertTrue(prompter.shouldSign(keyName: "id_ed25519", endpoint: "h:22"))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
    }

    func testRefusalIsReportedAsRefusal() {
        let prompter = AgentSignPrompter(present: { _, _, respond in respond(false) })
        let answered = expectation(description: "answered")
        DispatchQueue.global().async {
            XCTAssertFalse(prompter.shouldSign(keyName: "k", endpoint: "h:22"))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
    }

    func testKeyNameAndEndpointReachThePrompt() {
        // The user cannot judge a signing request without both: which key is
        // being used, and who is asking.
        var seen: (String, String)?
        let prompter = AgentSignPrompter(present: { key, endpoint, respond in
            seen = (key, endpoint)
            respond(false)
        })
        let answered = expectation(description: "answered")
        DispatchQueue.global().async {
            _ = prompter.shouldSign(keyName: "id_ed25519", endpoint: "example.com:22")
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(seen?.0, "id_ed25519")
        XCTAssertEqual(seen?.1, "example.com:22")
    }

    /// There is deliberately no timeout on `shouldSign`: a request that times
    /// out and refuses on its own is indistinguishable, from the SSH thread's
    /// perspective, from one a human explicitly denied — except that no human
    /// looked at it. Silently refusing after a delay is worse than waiting
    /// for one, because it trains the remote side (and the user) to expect
    /// automatic behaviour from what is supposed to be a manual gate.
    ///
    /// So the safety property to test isn't "it gives up eventually" — it's
    /// "it returns exactly, and only, what `respond` was called with, as
    /// soon as `respond` is called." A `present` that never calls `respond`
    /// at all correctly hangs forever; that is not this test. This test
    /// answers on a delayed background hop (simulating a slow but real user
    /// decision, not a fast in-line one) and asserts the call unblocks
    /// promptly with the right value once — and only once — that answer
    /// arrives.
    func testReturnsPromptlyAndExactlyOnceRespondIsCalled() {
        let prompter = AgentSignPrompter(present: { _, _, respond in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                respond(true)
            }
        })

        let answered = expectation(description: "answered")
        let start = DispatchTime.now()
        var elapsed: DispatchTimeInterval = .never
        DispatchQueue.global().async {
            let result = prompter.shouldSign(keyName: "k", endpoint: "h:22")
            let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            elapsed = .nanoseconds(Int(nanos))
            XCTAssertTrue(result)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)

        // Unblocked close to when `respond` was actually called (~0.2s), not
        // after some unrelated ceiling — confirms there's no hidden timeout
        // path racing the real answer.
        if case .nanoseconds(let nanos) = elapsed {
            XCTAssertLessThan(nanos, 1_000_000_000, "shouldSign did not return promptly after respond() was called")
        } else {
            XCTFail("elapsed time was not recorded")
        }
    }

    /// Sloop allows several terminal sessions at once (`SessionsModel`), so
    /// more than one SSH thread can call `shouldSign` on the *same* shared
    /// `AgentSignPrompter` around the same moment — two hosts both asking to
    /// sign. `prompt` is a single slot: without a queue, a second request
    /// that arrives before the first has been answered overwrites it, and
    /// the first request's SSH thread then hangs forever, because nothing
    /// still holds a reference to its `respond` closure once the sheet has
    /// moved on to the second request.
    ///
    /// This deliberately does NOT use `present:` injection. An injected
    /// closure receives its own request straight from `shouldSign` and never
    /// touches the shared `prompt` slot at all — every existing test in this
    /// file relies on exactly that isolation, which is also exactly why none
    /// of them can see this bug. To reproduce it, this test plays the role
    /// of the sheet itself, against the real default presenter
    /// (`present: nil`): it observes `$prompt`, and — after a short,
    /// realistic delay, so the *other* concurrent request has time to land
    /// first if nothing is stopping it — answers whatever is actually
    /// showing at that moment, exactly as `AgentSignPromptView` would. If the
    /// slot has moved on to a different request in the meantime, this
    /// answers that one and leaves the original unanswered, exactly as the
    /// real UI would.
    func testConcurrentRequestsAreQueuedNotDroppedOrCrossed() {
        let prompter = AgentSignPrompter()

        var seen: [(String, String)] = []
        let seenLock = NSLock()
        let bothShown = expectation(description: "both requests reached the sheet")
        bothShown.expectedFulfillmentCount = 2

        let cancellable = prompter.$prompt.compactMap { $0 }.sink { shown in
            seenLock.lock()
            seen.append((shown.keyName, shown.endpoint))
            seenLock.unlock()
            bothShown.fulfill()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Answer whatever is actually on screen right now — not
                // necessarily `shown` — exactly what looking at the sheet
                // and tapping a button would do, and exactly how the bug
                // loses a request: by the time this fires, `prompter.prompt`
                // may already have moved on.
                guard let current = prompter.prompt, current.id == shown.id else { return }
                current.respond(shown.keyName == "id_ed25519")
            }
        }
        defer { cancellable.cancel() }

        let firstAnswered = expectation(description: "id_ed25519 shouldSign returned")
        let secondAnswered = expectation(description: "id_rsa shouldSign returned")
        var firstResult: Bool?
        var secondResult: Bool?

        DispatchQueue.global().async {
            firstResult = prompter.shouldSign(keyName: "id_ed25519", endpoint: "a.example:22")
            firstAnswered.fulfill()
        }
        DispatchQueue.global().async {
            secondResult = prompter.shouldSign(keyName: "id_rsa", endpoint: "b.example:22")
            secondAnswered.fulfill()
        }

        wait(for: [bothShown, firstAnswered, secondAnswered], timeout: 2)

        XCTAssertEqual(seen.count, 2,
                        "the second request must actually reach the sheet, not be silently dropped by the first overwriting it")
        XCTAssertEqual(firstResult, true, "the id_ed25519 request should get its own answer")
        XCTAssertEqual(secondResult, false, "the id_rsa request should get its own answer, not the other request's")
    }
}
