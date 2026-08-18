// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
import SloopKit
import SwiftTerm
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS
// The transports, dialers and keychain stores live in the framework the app
// shares with the File Provider extension, not in the app target.
@testable import SloopSSH

/// Unit tests that run against the built macOS app (`@testable import Sloop`),
/// exercising app-layer code that the pure-Foundation SloopKit tests can't
/// reach. Run in CI via `xcodebuild test -scheme Sloop_macOS`.
final class SloopAppTests: XCTestCase {

    /// A Transport that just records what the terminal sends to it, and lets a
    /// test drive its open/close callbacks.
    private final class ProbeTransport: Transport {
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onOpen: (() -> Void)?
        var onClose: ((Error?) -> Void)?
        private(set) var sent: [UInt8] = []
        func start() {}
        func send(_ bytes: ArraySlice<UInt8>) { sent.append(contentsOf: bytes) }
        func resize(cols: Int, rows: Int) {}
        func close() {}
    }

    /// A transport must not outlive its controller.
    ///
    /// The callbacks in `wire(_:)` are stored *on* the transport, so capturing
    /// it strongly there makes it retain itself and never deallocate. That
    /// matters beyond tidiness: `LibSSH2Transport` holds a `Credential` with
    /// the private key, its passphrase and any password as plaintext strings,
    /// so a leak pins key material in memory for the life of the process and
    /// closing a tab does not release it.
    @MainActor
    func testTransportIsNotRetainedByItsOwnCallbacks() {
        weak var leaked: ProbeTransport?
        do {
            let probe = ProbeTransport()
            leaked = probe
            var controller: TerminalController? =
                TerminalController(makeTransport: { probe }, onConnectCommand: "tmux a")
            probe.onOpen?()          // exercise the capture in onOpen
            probe.onClose?(nil)
            controller = nil
        }
        drainMainQueue()

        XCTAssertNil(leaked,
                     "the transport outlived its controller — a callback stored on it "
                     + "captured it strongly, pinning the credential it holds")
    }

    /// The host's on-connect command is typed into the shell once the
    /// transport opens.
    @MainActor
    func testOnConnectCommandIsSentWhenTransportOpens() {
        let probe = ProbeTransport()
        let controller = TerminalController(makeTransport: { probe },
                                            onConnectCommand: "tmux attach || tmux new")

        XCTAssertTrue(probe.sent.isEmpty, "nothing should be sent before the link opens")
        probe.onOpen?()
        drainMainQueue()

        XCTAssertEqual(String(decoding: probe.sent, as: UTF8.self),
                       "tmux attach || tmux new\n")
        withExtendedLifetime(controller) {}
    }

    /// It must run again on every reconnect — landing back in tmux after a
    /// dropped link is the whole point of the feature.
    @MainActor
    func testOnConnectCommandRunsAgainAfterReconnect() {
        let probe = ProbeTransport()
        let controller = TerminalController(makeTransport: { probe },
                                            onConnectCommand: "tmux a")
        probe.onOpen?()
        drainMainQueue()
        probe.onClose?(nil)
        drainMainQueue()          // reconnect() is a no-op until state is disconnected

        controller.reconnect()
        probe.onOpen?()
        drainMainQueue()

        XCTAssertEqual(String(decoding: probe.sent, as: UTF8.self), "tmux a\ntmux a\n")
    }

    /// A blank command must not send a bare newline, which would leave a stray
    /// prompt at the top of every session.
    @MainActor
    func testBlankOnConnectCommandSendsNothing() {
        let probe = ProbeTransport()
        let controller = TerminalController(makeTransport: { probe },
                                            onConnectCommand: "   ")
        probe.onOpen?()
        drainMainQueue()

        XCTAssertTrue(probe.sent.isEmpty)
        withExtendedLifetime(controller) {}
    }

    /// The terminal controller must forward terminal keystrokes to the transport.
    @MainActor
    func testTerminalControllerForwardsKeystrokesToTransport() {
        let probe = ProbeTransport()
        let controller = TerminalController(transport: probe)

        controller.send(source: controller.terminalView,
                        data: ArraySlice(Array("ls -la\n".utf8)))

        XCTAssertEqual(probe.sent, Array("ls -la\n".utf8))
    }

    /// A terminal size change must be forwarded to the transport.
    @MainActor
    func testTerminalControllerForwardsResize() {
        final class ResizeProbe: Transport {
            var onData: ((ArraySlice<UInt8>) -> Void)?
            var onOpen: (() -> Void)?
            var onClose: ((Error?) -> Void)?
            var lastSize: (cols: Int, rows: Int)?
            func start() {}
            func send(_ bytes: ArraySlice<UInt8>) {}
            func resize(cols: Int, rows: Int) { lastSize = (cols, rows) }
            func close() {}
        }
        let probe = ResizeProbe()
        let controller = TerminalController(transport: probe)

        controller.sizeChanged(source: controller.terminalView, newCols: 120, newRows: 40)

        XCTAssertEqual(probe.lastSize?.cols, 120)
        XCTAssertEqual(probe.lastSize?.rows, 40)
    }

    /// The controller starts out connecting and reflects the transport's
    /// open/close callbacks in its published `state`.
    @MainActor
    func testControllerReflectsConnectionState() {
        let probe = ProbeTransport()
        let controller = TerminalController(transport: probe)
        XCTAssertEqual(controller.state, .connecting)

        probe.onOpen?()
        drainMainQueue()
        XCTAssertTrue(controller.state.isConnected)

        probe.onClose?(SSHError.channelFailure("dropped"))
        drainMainQueue()
        XCTAssertTrue(controller.state.isDisconnected)
    }

    /// Let queued main-queue blocks (the controller hops to main in its
    /// callbacks) run before asserting.
    @MainActor
    private func drainMainQueue() {
        let done = expectation(description: "main drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    /// The transport factory always yields a usable transport. Without the
    /// libssh2 framework it returns the `MessageTransport` fallback, which emits
    /// its explanation and closes immediately.
    @MainActor
    func testTransportFactoryProducesUsableTransport() {
        let host = SSHHost(alias: "t", hostname: "example.com", username: "u")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-app-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let transport = TransportFactory.ssh(host: host,
                                             credential: Credential(),
                                             knownHosts: KnownHostsStore(fileURL: tmp),
                                             hostKeyVerifier: AutoAcceptHostKeyVerifier(),
                                             accessTokens: InMemoryAccessTokenStore())
        XCTAssertNotNil(transport as AnyObject)

        #if !canImport(CSSH)
        var text = ""
        var closed = false
        transport.onData = { text += String(decoding: $0, as: UTF8.self) }
        transport.onClose = { _ in closed = true }
        transport.start()
        XCTAssertTrue(text.contains("SSH"))
        XCTAssertTrue(closed)
        #endif
    }

    /// A Cloudflare Access hostname that can't form a `wss://` URL (a typo
    /// with a stray space, here) must be reported as a hostname problem, not
    /// as "needs a login" — signing in cannot fix a malformed hostname, and
    /// telling the user to do so traps them in a loop. Only meaningful when
    /// CSSH is linked: without it, every host gets the same "not built in"
    /// message regardless of connection method.
    #if canImport(CSSH)
    @MainActor
    func testTransportFactoryReportsMalformedCloudflareAccessHostnameDistinctly() {
        let host = SSHHost(alias: "t", hostname: "exa mple.com", username: "u",
                           connectionMethod: .cloudflareAccess)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-app-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let transport = TransportFactory.ssh(host: host,
                                             credential: Credential(),
                                             knownHosts: KnownHostsStore(fileURL: tmp),
                                             hostKeyVerifier: AutoAcceptHostKeyVerifier(),
                                             accessTokens: InMemoryAccessTokenStore())
        var text = ""
        transport.onData = { text += String(decoding: $0, as: UTF8.self) }
        transport.start()

        XCTAssertTrue(text.contains("exa mple.com"), "should name the hostname: \(text)")
        XCTAssertTrue(text.lowercased().contains("hostname"),
                      "should say the hostname is the problem: \(text)")
        XCTAssertFalse(text.lowercased().contains("login"),
                       "a malformed hostname is not a login problem: \(text)")
    }

    /// An empty hostname is the same configuration error as a malformed one,
    /// and `URL(string:)` does not catch it: `"wss://"` parses perfectly well
    /// as a URL with no host. That got dialed, and the user waited out the
    /// full 20 s connect timeout to be told nothing useful.
    @MainActor
    func testTransportFactoryReportsEmptyCloudflareAccessHostnameDistinctly() {
        let host = SSHHost(alias: "t", hostname: "", username: "u",
                           connectionMethod: .cloudflareAccess)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-app-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let transport = TransportFactory.ssh(host: host,
                                             credential: Credential(),
                                             knownHosts: KnownHostsStore(fileURL: tmp),
                                             hostKeyVerifier: AutoAcceptHostKeyVerifier(),
                                             accessTokens: InMemoryAccessTokenStore())
        var text = ""
        transport.onData = { text += String(decoding: $0, as: UTF8.self) }
        transport.start()

        XCTAssertTrue(text.lowercased().contains("hostname"),
                      "should say the hostname is the problem: \(text)")
        XCTAssertFalse(text.lowercased().contains("login"),
                       "a blank hostname is not a login problem: \(text)")
    }

    /// The token-missing case must still read as a login problem — the host
    /// list's pre-connect gate (`HostListModel.needsAccessLogin`) is built on
    /// this message staying put.
    @MainActor
    func testTransportFactoryReportsMissingAccessTokenAsLoginRequired() {
        let host = SSHHost(alias: "t", hostname: "example.com", username: "u",
                           connectionMethod: .cloudflareAccess)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-app-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let transport = TransportFactory.ssh(host: host,
                                             credential: Credential(),
                                             knownHosts: KnownHostsStore(fileURL: tmp),
                                             hostKeyVerifier: AutoAcceptHostKeyVerifier(),
                                             accessTokens: InMemoryAccessTokenStore())
        var text = ""
        transport.onData = { text += String(decoding: $0, as: UTF8.self) }
        transport.start()

        XCTAssertTrue(text.contains("browser login"), "should ask for a login: \(text)")
        XCTAssertTrue(text.contains("example.com"), "should name the hostname: \(text)")
    }

    /// `CommandRunnerFactory` must refuse to build a directly-dialing runner
    /// for a tunneled host on its own terms — not merely because its one
    /// caller (the Mosh probe in `HostListModel.connect`) happens to restrict
    /// itself to `.direct` hosts today. If that caller-side guard is ever
    /// relaxed, this is what stops SSH credentials from going straight to the
    /// Access hostname's public port 22.
    @MainActor
    func testCommandRunnerFactoryRefusesTunneledHosts() {
        let host = SSHHost(alias: "t", hostname: "example.com", username: "u",
                           connectionMethod: .cloudflareAccess)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sloop-app-known-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let runner = CommandRunnerFactory.ssh(host: host,
                                              credential: Credential(),
                                              knownHosts: KnownHostsStore(fileURL: tmp),
                                              hostKeyVerifier: AutoAcceptHostKeyVerifier())

        let done = expectation(description: "run completed")
        runner.run("echo hi") { result in
            switch result {
            case .success:
                XCTFail("a tunneled host must not run commands over a direct dial")
            case .failure(let error):
                guard case SSHError.notImplemented(let why) = error else {
                    return XCTFail("expected notImplemented, got \(error)")
                }
                XCTAssertTrue(why.contains("tunnel"), why)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }

    // MARK: - TokenClearingDialer (stranded-host fix)

    /// A `Dialer` whose `dial()` outcome is fixed at init, for driving
    /// `TokenClearingDialer` without a real network handshake.
    private final class StubDialer: Dialer {
        private let result: Result<Int32, Error>
        init(result: Result<Int32, Error>) { self.result = result }
        func dial() throws -> Int32 { try result.get() }
    }

    /// A rejected-but-locally-unexpired token (revoked session, new
    /// device-posture rule, wrong-app cookie — anything the edge itself
    /// refuses) must be cleared so the next `needsAccessLogin` check opens
    /// the login sheet instead of retrying the same dead token forever.
    @MainActor
    func testTokenClearingDialerClearsTokenOnAccessLoginRequired() throws {
        let tokens = InMemoryAccessTokenStore()
        try tokens.setRawToken("stale-token", for: "ssh.example.com")
        let failing = StubDialer(result: .failure(SSHError.accessLoginRequired(host: "ssh.example.com")))
        let dialer = TokenClearingDialer(wrapping: failing, hostname: "ssh.example.com",
                                         accessTokens: tokens)

        XCTAssertThrowsError(try dialer.dial()) { error in
            guard case SSHError.accessLoginRequired = error else {
                return XCTFail("must rethrow the original error unchanged, got \(error)")
            }
        }
        XCTAssertNil(tokens.rawToken(for: "ssh.example.com"),
                    "a rejected token must not survive to strand the next connect attempt")
    }

    /// Same clearing behavior for a policy-level denial, not just an
    /// expired/missing session.
    @MainActor
    func testTokenClearingDialerClearsTokenOnAccessDenied() throws {
        let tokens = InMemoryAccessTokenStore()
        try tokens.setRawToken("stale-token", for: "ssh.example.com")
        let failing = StubDialer(result: .failure(SSHError.accessDenied(host: "ssh.example.com")))
        let dialer = TokenClearingDialer(wrapping: failing, hostname: "ssh.example.com",
                                         accessTokens: tokens)

        XCTAssertThrowsError(try dialer.dial())
        XCTAssertNil(tokens.rawToken(for: "ssh.example.com"))
    }

    /// A plain network hiccup is not "the edge rejected this token" and must
    /// not throw away a token that might still be perfectly good.
    @MainActor
    func testTokenClearingDialerKeepsTokenOnOtherFailures() throws {
        let tokens = InMemoryAccessTokenStore()
        try tokens.setRawToken("still-good-token", for: "ssh.example.com")
        let failing = StubDialer(result: .failure(SSHError.connectionFailed("timed out")))
        let dialer = TokenClearingDialer(wrapping: failing, hostname: "ssh.example.com",
                                         accessTokens: tokens)

        XCTAssertThrowsError(try dialer.dial()) { error in
            guard case SSHError.connectionFailed = error else {
                return XCTFail("must rethrow the original error unchanged, got \(error)")
            }
        }
        XCTAssertEqual(tokens.rawToken(for: "ssh.example.com"), "still-good-token")
    }

    /// A successful dial must pass the fd through untouched.
    @MainActor
    func testTokenClearingDialerPassesThroughSuccess() throws {
        let tokens = InMemoryAccessTokenStore()
        let dialer = TokenClearingDialer(wrapping: StubDialer(result: .success(42)),
                                         hostname: "ssh.example.com", accessTokens: tokens)
        XCTAssertEqual(try dialer.dial(), 42)
    }
    #endif
}
