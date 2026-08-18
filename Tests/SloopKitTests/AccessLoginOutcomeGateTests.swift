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
}
