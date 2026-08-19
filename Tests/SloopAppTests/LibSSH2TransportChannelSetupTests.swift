// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS
import SloopKit

#if canImport(CSSH)

/// `LibSSH2Transport.configureChannel` — the order in which `openShell` asks
/// for a PTY, agent forwarding, and the shell itself.
///
/// No unit test can see sshd's SSH_CHANNEL_LARVAL/OPEN state machine or its
/// child process's environment, which is the actual thing that makes wrong
/// ordering here silently fail against a real server (see the doc comment on
/// `configureChannel` for exactly how). What a test *can* see is which of two
/// closures a pure function calls first — so `configureChannel` was pulled
/// out specifically to make that observable, with recording closures standing
/// in for the real libssh2 calls.
final class LibSSH2TransportChannelSetupTests: XCTestCase {
    func testAuthAgentIsRequestedBeforeTheShell() {
        var order: [String] = []

        let ok = LibSSH2Transport.configureChannel(
            requestForwarding: true,
            requestPTY: { order.append("pty"); return 0 },
            requestAuthAgent: { order.append("authAgent"); return 0 },
            startShell: { order.append("shell"); return 0 },
            onForwardingFailed: { _ in XCTFail("should not be called on success") })

        XCTAssertTrue(ok)
        XCTAssertEqual(order, ["pty", "authAgent", "shell"],
                       "the auth-agent request must be issued before the shell request")
    }

    func testForwardingNotRequestedWhenThereIsNothingToForward() {
        var authAgentCalled = false

        let ok = LibSSH2Transport.configureChannel(
            requestForwarding: false,
            requestPTY: { 0 },
            requestAuthAgent: { authAgentCalled = true; return 0 },
            startShell: { 0 },
            onForwardingFailed: { _ in XCTFail("should not be called") })

        XCTAssertTrue(ok)
        XCTAssertFalse(authAgentCalled)
    }

    /// A server that refuses the forwarding request (or doesn't support it)
    /// must not lose the shell over it.
    func testAFailedForwardingRequestIsNonFatalAndTheShellStillStarts() {
        var shellStarted = false
        var reportedFailureCode: Int32?

        let ok = LibSSH2Transport.configureChannel(
            requestForwarding: true,
            requestPTY: { 0 },
            requestAuthAgent: { -37 },
            startShell: { shellStarted = true; return 0 },
            onForwardingFailed: { rc in reportedFailureCode = rc })

        XCTAssertTrue(ok)
        XCTAssertTrue(shellStarted, "a working shell that can't forward beats no shell at all")
        XCTAssertEqual(reportedFailureCode, -37)
    }

    func testAFailedPTYRequestNeverReachesForwardingOrTheShell() {
        var authAgentCalled = false
        var shellCalled = false

        let ok = LibSSH2Transport.configureChannel(
            requestForwarding: true,
            requestPTY: { -1 },
            requestAuthAgent: { authAgentCalled = true; return 0 },
            startShell: { shellCalled = true; return 0 },
            onForwardingFailed: { _ in })

        XCTAssertFalse(ok)
        XCTAssertFalse(authAgentCalled)
        XCTAssertFalse(shellCalled)
    }

    // MARK: wantsForwarding — the resolved-keys gate

    /// A transport is always constructed from the already-RESOLVED
    /// `[NamedKey]` list (`TransportFactory` builds it via
    /// `KeyLibrary.forwardedKeys`, which drops any selected name that no
    /// longer resolves to a library key). `wantsForwarding` must reflect that
    /// list alone.
    func testWantsForwardingIsTrueWhenThereAreResolvedKeys() throws {
        let transport = try makeTransport(forwardedKeys: [NamedKey(name: "k", privateKeyPEM: "PEM")])
        XCTAssertTrue(transport.wantsForwarding)
    }

    func testWantsForwardingIsFalseWithNoResolvedKeys() throws {
        let transport = try makeTransport(forwardedKeys: [])
        XCTAssertFalse(transport.wantsForwarding)
    }

    /// The exact shape of the review-2 bug: a host whose selected key NAMES
    /// are non-empty (so `host.forwardsAgent` reads true) but every one of
    /// those names has since been deleted from the library, so
    /// `KeyLibrary.forwardedKeys` resolves to nothing. The old code asked
    /// `openShell` to request forwarding based on `host.forwardsAgent`, while
    /// `forwardedAgent` was built from the resolved (empty) list — so the
    /// request went out with nothing listening for the channel it opened,
    /// and the remote blocked forever on it. `wantsForwarding` must side with
    /// the resolved list, not the host's raw selection, regardless of what
    /// `host.forwardsAgent` says.
    func testWantsForwardingIgnoresHostForwardsAgentWhenNothingResolved() throws {
        var host = SSHHost(alias: "a", hostname: "h", username: "u")
        host.forwardedKeys = ["gone"]
        XCTAssertTrue(host.forwardsAgent, "sanity: the host's own flag has no idea the key is missing")

        // TransportFactory would have resolved "gone" via
        // KeyLibrary.forwardedKeys before construction; because the key no
        // longer exists, that resolution is empty — exactly what's passed in
        // here.
        let transport = try makeTransport(host: host, forwardedKeys: [])
        XCTAssertFalse(transport.wantsForwarding,
                       "must not want to request forwarding when nothing resolved, " +
                       "regardless of host.forwardsAgent")
    }

    // MARK: Fixtures

    private func makeTransport(host: SSHHost = SSHHost(alias: "a", hostname: "h", username: "u"),
                               forwardedKeys: [NamedKey]) throws -> LibSSH2Transport {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-channel-setup-known-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        return LibSSH2Transport(host: host, credential: Credential(),
                                dialer: NeverDialingDialer(),
                                knownHosts: KnownHostsStore(fileURL: tmp),
                                forwardedKeys: forwardedKeys)
    }
}

/// A `Dialer` that is never actually asked to dial — these tests only
/// construct a `LibSSH2Transport` and read its properties, never call
/// `start()`/`run()`, so no network is involved.
private final class NeverDialingDialer: Dialer {
    func dial() throws -> Int32 {
        fatalError("not expected to be called — these tests never run()")
    }
}
#endif
