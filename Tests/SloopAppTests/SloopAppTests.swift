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
