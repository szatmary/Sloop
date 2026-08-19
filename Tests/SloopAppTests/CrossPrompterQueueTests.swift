// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Combine
import XCTest
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS

/// `PromptQueue` serializes concurrent requests. `HostListView` attaches two
/// independent `.sheet(item:)` modifiers to the same view — one for
/// `HostKeyPrompter.shared.prompt`, one for `AgentSignPrompter.shared.prompt`.
/// If those two prompters queued their own requests independently of each
/// other (as an earlier version of this codebase did — each with its own
/// private `PromptQueue<Payload>`), nothing would stop both `prompt`s from
/// going non-nil at once: a host-key prompt from one session concurrent with
/// a sign prompt from another. SwiftUI can only actually present one sheet
/// from one view at a time — the second's content is never shown, so nothing
/// ever calls its `respond`, and that SSH thread hangs forever. The fix
/// (`AgentSignPrompter.shared`/`HostKeyPrompter.shared` both handing their
/// requests to the same `PromptQueue.shared`) is what this test proves: it
/// constructs its own `HostKeyPrompter`/`AgentSignPrompter` pair, deliberately
/// pointed at one shared `PromptQueue()` instance (not `.shared` itself, to
/// stay isolated from any other test), exactly mirroring how the real
/// `.shared` singletons are wired.
final class CrossPrompterQueueTests: XCTestCase {
    /// Issues one host-key request and one sign request concurrently, and
    /// answers them with DIFFERENT decisions (trust / deny) so a crossed
    /// answer would be caught too, not just a dropped one.
    ///
    /// This deliberately drives both prompters' DEFAULT presenters — an
    /// injected `present:` bypasses `@Published var prompt` entirely, which
    /// is exactly the mechanism this test needs to exercise (the lesson from
    /// the single-prompter fix: an injection seam cannot see this class of
    /// bug).
    ///
    /// A plain XCTest has no real `.sheet` machinery, so nothing here can
    /// force AppKit/SwiftUI's actual "only one sheet may be presented from
    /// one view at a time" rule to fire on its own. What a headless test CAN
    /// do is model that rule explicitly, the same way the single-prompter
    /// tests model "the sheet" with a Combine subscription instead of a real
    /// `HostKeyPromptView`/`AgentSignPromptView`: `showingSomething` below
    /// stands in for "a sheet is already up," matching what SwiftUI would
    /// actually do — refuse to present a second sheet from the same view,
    /// which means nobody ever taps a button on it, which means its
    /// `respond` is never called. A second prompt that arrives while the
    /// first is still showing is deliberately left untouched here, exactly
    /// as an ignored second `.sheet` presentation attempt would be. Against
    /// the fixed code this branch is never actually exercised — the shared
    /// queue never presents two prompts at once — but it stays in place so
    /// the test's own assertions remain meaningful (and, run against a
    /// regression that reintroduces two independent queues, it is exactly
    /// what catches it again).
    func testConcurrentHostKeyAndSignRequestsAreQueuedNotDroppedOrCrossed() {
        let sharedQueue = PromptQueue()
        let hostKeyPrompter = HostKeyPrompter(queue: sharedQueue)
        let agentSignPrompter = AgentSignPrompter(queue: sharedQueue)

        let stateLock = NSLock()
        var showingSomething = false
        var sawHostKeyPrompt = false
        var sawAgentSignPrompt = false

        let hostKeyCancellable = hostKeyPrompter.$prompt.compactMap { $0 }.sink { shown in
            stateLock.lock()
            let alreadyShowing = showingSomething
            if !alreadyShowing { showingSomething = true }
            stateLock.unlock()
            // A real second `.sheet` presentation would be refused by
            // SwiftUI while the first is still up — this mirrors that by
            // simply not engaging with it, exactly as no button in an
            // unshown sheet can ever be tapped.
            guard !alreadyShowing else { return }
            sawHostKeyPrompt = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard hostKeyPrompter.prompt?.id == shown.id else { return }
                shown.respond(true)   // trust
                stateLock.lock(); showingSomething = false; stateLock.unlock()
            }
        }

        let agentSignCancellable = agentSignPrompter.$prompt.compactMap { $0 }.sink { shown in
            stateLock.lock()
            let alreadyShowing = showingSomething
            if !alreadyShowing { showingSomething = true }
            stateLock.unlock()
            guard !alreadyShowing else { return }
            sawAgentSignPrompt = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard agentSignPrompter.prompt?.id == shown.id else { return }
                shown.respond(false)  // deny
                stateLock.lock(); showingSomething = false; stateLock.unlock()
            }
        }
        defer {
            hostKeyCancellable.cancel()
            agentSignCancellable.cancel()
        }

        let hostKeyAnswered = expectation(description: "host-key shouldTrust returned")
        let agentSignAnswered = expectation(description: "agent-sign shouldSign returned")
        var hostKeyResult: Bool?
        var agentSignResult: Bool?

        DispatchQueue.global().async {
            hostKeyResult = hostKeyPrompter.shouldTrust(endpoint: "a.example:22",
                                                         keyType: "ssh-ed25519",
                                                         fingerprint: "AAAA")
            hostKeyAnswered.fulfill()
        }
        DispatchQueue.global().async {
            agentSignResult = agentSignPrompter.shouldSign(keyName: "id_ed25519", endpoint: "b.example:22")
            agentSignAnswered.fulfill()
        }

        wait(for: [hostKeyAnswered, agentSignAnswered], timeout: 2)

        XCTAssertTrue(sawHostKeyPrompt, "the host-key request must actually reach a sheet")
        XCTAssertTrue(sawAgentSignPrompt,
                      "the sign request must actually reach a sheet, not be silently dropped behind the host-key one")
        XCTAssertEqual(hostKeyResult, true, "the host-key request should get its own answer")
        XCTAssertEqual(agentSignResult, false, "the sign request should get its own answer, not the other request's")
    }
}
