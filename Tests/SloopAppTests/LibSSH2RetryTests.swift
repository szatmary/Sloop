// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if canImport(CSSH)
import XCTest
import CSSH
import SloopKit
@testable import SloopSSH

/// When an EAGAIN loop is allowed to stop.
///
/// Every pre-loop phase — handshake, host-key check, authentication, channel
/// open, the PTY and shell requests — sits in one of these, and none of them
/// could be stopped: `shouldClose` was read only inside the event loop, which
/// a stuck connect never reaches. The loop itself needs a real server (or a
/// real tarpit) to exercise, so the decision is tested and the plumbing around
/// it is read.
final class LibSSH2RetryStepTests: XCTestCase {

    func testANonEAGAINResultFinishesImmediately() {
        XCTAssertEqual(LibSSH2Connection.retryStep(rc: 0, isCancelled: false, isPastDeadline: false),
                       .finished(0))
        XCTAssertEqual(LibSSH2Connection.retryStep(rc: -19, isCancelled: false, isPastDeadline: false),
                       .finished(-19))
    }

    func testEAGAINWaitsForTheSocket() {
        XCTAssertEqual(LibSSH2Connection.retryStep(rc: LIBSSH2_ERROR_EAGAIN,
                                                   isCancelled: false, isPastDeadline: false),
                       .wait)
    }

    /// The tab was closed. Before this, `close()` was not honoured until the
    /// event loop started — so a connection stuck in auth held its thread,
    /// socket and credential strings until the process died.
    func testCancellationStopsAnEAGAINLoop() {
        XCTAssertEqual(LibSSH2Connection.retryStep(rc: LIBSSH2_ERROR_EAGAIN,
                                                   isCancelled: true, isPastDeadline: false),
                       .giveUp)
    }

    /// Nobody is watching. A port that completes TCP and then says nothing —
    /// a tarpit, a non-SSH service, a middlebox — would otherwise poll at
    /// 200 ms a turn for the life of the process.
    func testTheDeadlineStopsAnEAGAINLoop() {
        XCTAssertEqual(LibSSH2Connection.retryStep(rc: LIBSSH2_ERROR_EAGAIN,
                                                   isCancelled: false, isPastDeadline: true),
                       .giveUp)
    }

    /// A call that just succeeded is not thrown away because the deadline
    /// passed, or the tab closed, while it was running. The result is already
    /// in hand and discarding it would fail a connection that worked.
    func testASuccessOnTheFinalPassIsKept() {
        XCTAssertEqual(LibSSH2Connection.retryStep(rc: 0, isCancelled: true, isPastDeadline: true),
                       .finished(0))
    }
}
#endif

/// The loop around `retryStep`, on a connection that was never dialled.
///
/// `waitSocket()` returns immediately with no session and no socket, so the
/// loop can be driven with a closure standing in for libssh2 — which is enough
/// to pin the two behaviours that matter: it asks every pass, and teardown is
/// not cut short by the very close that triggered it.
#if canImport(CSSH)
extension LibSSH2RetryStepTests {
    private final class UnusedDialer: Dialer {
        func dial() throws -> Int32 { throw SSHError.connectionFailed("never dialled") }
    }

    private func makeConnection() -> LibSSH2Connection {
        let knownHosts = KnownHostsStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("retry-known-hosts-\(UUID().uuidString)"))
        return LibSSH2Connection(host: SSHHost(alias: "box",
                                               hostname: "example.com",
                                               username: "matt"),
                                 credential: Credential(password: "unused"),
                                 dialer: UnusedDialer(),
                                 knownHosts: knownHosts,
                                 hostKeyVerifier: StrictHostKeyVerifier())
    }

    /// Asked after every attempt, not once before the first. A `close()` that
    /// arrives while libssh2 is mid-handshake has to be seen.
    func testRetryAsksAboutCancellationOnEveryPass() {
        let connection = makeConnection()
        var attempts = 0
        connection.isCancelled = { attempts >= 3 }

        let rc = connection.retry {
            attempts += 1
            return LIBSSH2_ERROR_EAGAIN
        }

        XCTAssertEqual(rc, LIBSSH2_ERROR_TIMEOUT)
        XCTAssertEqual(attempts, 3, "it should stop on the pass where cancellation became true")
    }

    func testRetryGivesUpOnceTheDeadlineHasPassed() {
        let connection = makeConnection()
        var attempts = 0

        let rc = connection.retry(until: Date().addingTimeInterval(-1)) {
            attempts += 1
            return LIBSSH2_ERROR_EAGAIN
        }

        XCTAssertEqual(rc, LIBSSH2_ERROR_TIMEOUT)
        XCTAssertEqual(attempts, 1, "one attempt, then the expired deadline ends it")
    }

    /// Teardown runs *because* the transport is closing, so a cancellable
    /// retry would give up on its first EAGAIN and turn every polite channel
    /// close into an abrupt one.
    func testTeardownRetryIsNotCutShortByCancellation() {
        let connection = makeConnection()
        connection.isCancelled = { true }
        var attempts = 0

        let rc = connection.retryDuringTeardown(within: 5) {
            attempts += 1
            return attempts < 3 ? LIBSSH2_ERROR_EAGAIN : 0
        }

        XCTAssertEqual(rc, 0, "the close should be allowed to complete")
        XCTAssertEqual(attempts, 3)
    }

    /// Bounded all the same: a peer that never acknowledges does not get to
    /// decide when teardown ends.
    func testTeardownRetryStillStopsAtItsDeadline() {
        let connection = makeConnection()
        let rc = connection.retryDuringTeardown(within: 0) { LIBSSH2_ERROR_EAGAIN }
        XCTAssertEqual(rc, LIBSSH2_ERROR_TIMEOUT)
    }
}
#endif
