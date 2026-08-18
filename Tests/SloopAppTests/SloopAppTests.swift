// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
import SloopKit
import SwiftTerm
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS

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
                                             hostKeyVerifier: AutoAcceptHostKeyVerifier())
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
}
