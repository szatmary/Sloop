// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

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
}
