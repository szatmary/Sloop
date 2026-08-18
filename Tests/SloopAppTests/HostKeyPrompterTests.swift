// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Combine
import XCTest
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS

final class HostKeyPrompterTests: XCTestCase {
    /// Sloop allows several terminal sessions at once (`SessionsModel`), so
    /// more than one SSH thread can call into the same shared
    /// `HostKeyPrompter` around the same moment — two hosts with unknown or
    /// changed keys, both connecting together. `prompt` is a single slot:
    /// without a queue, a second request that arrives before the first has
    /// been answered overwrites it, and the first request's SSH thread then
    /// hangs forever, because nothing still holds a reference to its
    /// `respond` closure once the sheet has moved on to the second request.
    ///
    /// This deliberately does NOT inject a presenter — as written,
    /// `HostKeyPrompter` has no injection seam at all; every request goes
    /// straight at `self.prompt`, so the default path is the only path. This
    /// test plays the role of the sheet itself: it observes `$prompt`, and —
    /// after a short, realistic delay, so the *other* concurrent request has
    /// time to land first if nothing is stopping it — answers whatever is
    /// actually showing at that moment, exactly as `HostKeyPromptView`
    /// would. If the slot has moved on to a different request in the
    /// meantime, this answers that one and leaves the original unanswered,
    /// exactly as the real UI would.
    ///
    /// The two requests are deliberately answered with DIFFERENT decisions
    /// (trust / refuse), and exercise both entry points (`shouldTrust` and
    /// `shouldTrustChangedKey`), so a crossed-answer bug is caught too, not
    /// just a dropped one.
    func testConcurrentRequestsAreQueuedNotDroppedOrCrossed() {
        let prompter = HostKeyPrompter()

        var seen: [String] = []
        let seenLock = NSLock()
        let bothShown = expectation(description: "both requests reached the sheet")
        bothShown.expectedFulfillmentCount = 2

        let cancellable = prompter.$prompt.compactMap { $0 }.sink { shown in
            seenLock.lock()
            seen.append(shown.endpoint)
            seenLock.unlock()
            bothShown.fulfill()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Answer whatever is actually on screen right now — not
                // necessarily `shown` — exactly what looking at the sheet and
                // tapping a button would do, and exactly how the bug loses a
                // request: by the time this fires, `prompter.prompt` may
                // already have moved on to the other one.
                guard let current = prompter.prompt, current.id == shown.id else { return }
                current.respond(shown.endpoint == "a.example:22")
            }
        }
        defer { cancellable.cancel() }

        let firstAnswered = expectation(description: "a.example shouldTrust returned")
        let secondAnswered = expectation(description: "b.example shouldTrustChangedKey returned")
        var firstResult: Bool?
        var secondResult: Bool?

        DispatchQueue.global().async {
            firstResult = prompter.shouldTrust(endpoint: "a.example:22",
                                                keyType: "ssh-ed25519",
                                                fingerprint: "AAAA")
            firstAnswered.fulfill()
        }
        DispatchQueue.global().async {
            secondResult = prompter.shouldTrustChangedKey(endpoint: "b.example:22",
                                                            keyType: "ssh-ed25519",
                                                            fingerprint: "BBBB",
                                                            previousFingerprint: "OLDFP")
            secondAnswered.fulfill()
        }

        wait(for: [bothShown, firstAnswered, secondAnswered], timeout: 2)

        XCTAssertEqual(seen.count, 2,
                        "the second request must actually reach the sheet, not be silently dropped by the first overwriting it")
        XCTAssertEqual(firstResult, true, "the a.example request should get its own answer")
        XCTAssertEqual(secondResult, false, "the b.example request should get its own answer, not the other request's")
    }
}
