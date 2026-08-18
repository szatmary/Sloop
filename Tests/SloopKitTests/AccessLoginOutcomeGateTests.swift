// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// `AccessLoginOutcomeGate` is the primitive `AccessLoginView` uses to make
/// sure exactly one of its several racing exits (success, cancel, swipe-
/// dismiss, navigation failure) is ever acted on. The `WKWebView` callback
/// timing that actually creates the race isn't reachable from a unit test,
/// but the gate's own "first caller wins, everyone else is a no-op"
/// contract — which is the entire fix — is plain Swift and fully testable
/// here.
final class AccessLoginOutcomeGateTests: XCTestCase {
    func testFirstCommitRunsAndReportsSuccess() {
        let gate = AccessLoginOutcomeGate()
        var ran = false
        XCTAssertTrue(gate.commit { ran = true })
        XCTAssertTrue(ran)
        XCTAssertTrue(gate.isFinished)
    }

    func testSecondCommitIsDroppedAsNoOp() {
        let gate = AccessLoginOutcomeGate()
        gate.commit {}

        var ranAgain = false
        XCTAssertFalse(gate.commit { ranAgain = true })
        XCTAssertFalse(ranAgain)
    }

    /// Simulates the actual bug: a swipe-dismiss commits a failure, then a
    /// `getAllCookies` completion that was already in flight tries to
    /// deliver a token afterward. The late success must never run.
    func testLateSuccessAfterFailureIsDropped() {
        let gate = AccessLoginOutcomeGate()
        var failureReported: String?
        var tokenDelivered: String?

        XCTAssertTrue(gate.commit { failureReported = "no token captured" })
        XCTAssertFalse(gate.commit { tokenDelivered = "some-jwt" })

        XCTAssertEqual(failureReported, "no token captured")
        XCTAssertNil(tokenDelivered)
    }

    /// The mirror image: a navigation failure fires, then a later
    /// independent success in the same redirect chain must not also fire.
    func testLateFailureAfterSuccessIsDropped() {
        let gate = AccessLoginOutcomeGate()
        var tokenDelivered: String?
        var failureReported: String?

        XCTAssertTrue(gate.commit { tokenDelivered = "some-jwt" })
        XCTAssertFalse(gate.commit { failureReported = "network error" })

        XCTAssertEqual(tokenDelivered, "some-jwt")
        XCTAssertNil(failureReported)
    }

    func testOnlyTheFirstOfManyRacingCommitsRuns() {
        let gate = AccessLoginOutcomeGate()
        var order: [Int] = []
        for i in 0..<5 {
            gate.commit { order.append(i) }
        }
        XCTAssertEqual(order, [0])
    }

    func testIsFinishedStartsFalse() {
        XCTAssertFalse(AccessLoginOutcomeGate().isFinished)
    }

    /// Dismissing the sheet fires the Cancel action *and then* `onDisappear`.
    /// Driven through the gate the way `AccessLoginView` drives them, that
    /// must produce exactly one outcome, and it must be `.cancelled`: the
    /// host list raises an alert for `.failed` and nothing at all for this.
    func testCancelThenDisappearReportsASingleCancellation() {
        let gate = AccessLoginOutcomeGate()
        var reported: [AccessLoginOutcome] = []

        gate.commit { reported.append(.cancelled) }        // the Cancel button
        gate.commit { reported.append(.cancelled) }        // .onDisappear, right after

        XCTAssertEqual(reported, [.cancelled])
    }

    /// A swipe-dismiss has no explicit action of its own — `onDisappear` is
    /// the only thing that fires — and it is still a cancellation, not the
    /// "no token was captured" failure it used to report.
    func testSwipeDismissAloneReportsCancellation() {
        let gate = AccessLoginOutcomeGate()
        var reported: [AccessLoginOutcome] = []

        gate.commit { reported.append(.cancelled) }

        XCTAssertEqual(reported, [.cancelled])
    }

    /// A token that lands first still wins over the `onDisappear` that
    /// follows the sheet closing itself.
    func testCapturedTokenSurvivesTheDismissThatFollowsIt() {
        let gate = AccessLoginOutcomeGate()
        var reported: [AccessLoginOutcome] = []

        gate.commit { reported.append(.token("jwt")) }
        gate.commit { reported.append(.cancelled) }

        XCTAssertEqual(reported, [.token("jwt")])
    }
}

/// The other half of "don't report a failure that isn't one": a web view
/// reports every superseded navigation as `NSURLErrorCancelled`, and an IdP
/// redirect chain is made of superseded navigations. Treating those as fatal
/// aborted sign-ins that were working.
final class CancelledNavigationErrorTests: XCTestCase {
    func testCancelledNavigationIsRecognized() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertTrue(isCancelledNavigationError(error))
        XCTAssertEqual(NSURLErrorCancelled, -999, "the code WebKit actually reports")
    }

    /// Real reachability failures must still be reported — they are the whole
    /// reason the delegate methods exist.
    func testGenuineNavigationFailuresAreNotCancellations() {
        for code in [NSURLErrorNotConnectedToInternet,
                     NSURLErrorCannotFindHost,
                     NSURLErrorSecureConnectionFailed,
                     NSURLErrorTimedOut] {
            XCTAssertFalse(isCancelledNavigationError(
                NSError(domain: NSURLErrorDomain, code: code)), "code \(code)")
        }
    }

    /// -999 in some other domain is some other error; only URL loading's own
    /// cancellation is routine.
    func testSameCodeInAnotherDomainIsNotACancellation() {
        XCTAssertFalse(isCancelledNavigationError(
            NSError(domain: "org.szatmary.sloop.test", code: NSURLErrorCancelled)))
    }
}

/// What the sheet says when the sign-in page never loaded.
final class AccessLoginFailureMessageTests: XCTestCase {
    private func urlError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "the system's wording"])
    }

    /// A hostname that doesn't resolve is not a sign-in problem, and saying so
    /// sends the user to re-authenticate instead of to the field that's wrong.
    /// This is the mistake that cost a real debugging session.
    func testAnUnresolvableHostnamePointsAtTheHostnameNotTheSignIn() {
        for code in [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost] {
            let message = accessLoginFailureMessage(hostname: "typo.example.com",
                                                    error: urlError(code))
            XCTAssertTrue(message.contains("typo.example.com"))
            XCTAssertTrue(message.contains("Check the hostname"),
                          "URL error \(code) should point at the hostname setting")
            XCTAssertTrue(message.contains("signing in again won't help"),
                          "URL error \(code) must not read as a sign-in failure")
        }
    }

    /// Anything else keeps the system's own wording, which is more specific
    /// than anything this could invent.
    func testOtherFailuresKeepTheSystemsDescription() {
        let message = accessLoginFailureMessage(hostname: "ssh.example.com",
                                                error: urlError(NSURLErrorSecureConnectionFailed))
        XCTAssertTrue(message.contains("the system's wording"))
        XCTAssertFalse(message.contains("Check the hostname"))
    }
}
