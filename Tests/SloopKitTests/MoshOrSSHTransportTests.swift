import XCTest
@testable import SloopKit

final class MoshOrSSHTransportTests: XCTestCase {

    /// Records that it was started and forwards output, so tests can see which
    /// inner transport the composition chose.
    private final class RecordingTransport: Transport {
        let name: String
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onOpen: (() -> Void)?
        var onClose: ((Error?) -> Void)?
        private(set) var started = false
        private(set) var sent: [UInt8] = []
        private(set) var lastSize: (cols: Int, rows: Int)?
        init(_ name: String) { self.name = name }
        func start() { started = true }
        func send(_ bytes: ArraySlice<UInt8>) { sent.append(contentsOf: bytes) }
        func resize(cols: Int, rows: Int) { lastSize = (cols, rows) }
        func close() {}
    }

    func testUsesSSHDirectlyWhenMoshNotRequested() {
        let ssh = RecordingTransport("ssh")
        let mosh = RecordingTransport("mosh")
        let t = MoshOrSSHTransport(
            useMosh: false,
            makeCommandRunner: { MockCommandRunner(stdout: "MOSH CONNECT 6 k\n") },
            makeSSHTransport: { ssh },
            makeMoshTransport: { _ in mosh })
        t.start()
        XCTAssertTrue(ssh.started)
        XCTAssertFalse(mosh.started)
    }

    func testFallsBackToSSHWhenServerMissing() {
        let ssh = RecordingTransport("ssh")
        var notice = ""
        let t = MoshOrSSHTransport(
            useMosh: true,
            makeCommandRunner: { MockCommandRunner(stderr: "bash: mosh-server: command not found\n", exitStatus: 127) },
            makeSSHTransport: { ssh })
        t.onData = { notice += String(decoding: $0, as: UTF8.self) }
        t.start()
        XCTAssertTrue(ssh.started)
        XCTAssertTrue(notice.contains("isn't installed"))
        XCTAssertTrue(notice.contains("using SSH"))
    }

    func testUsesMoshWhenAvailableAndTransportProvided() {
        let ssh = RecordingTransport("ssh")
        let mosh = RecordingTransport("mosh")
        var capturedPort: Int?
        let t = MoshOrSSHTransport(
            useMosh: true,
            makeCommandRunner: { MockCommandRunner(stdout: "MOSH CONNECT 60007 keydata==\n") },
            makeSSHTransport: { ssh },
            makeMoshTransport: { bootstrap in
                capturedPort = bootstrap.udpPort
                return mosh
            })
        t.start()
        XCTAssertTrue(mosh.started)
        XCTAssertFalse(ssh.started)
        XCTAssertEqual(capturedPort, 60007)
    }

    func testFallsBackWhenMoshAvailableButNoTransportWired() {
        let ssh = RecordingTransport("ssh")
        var notice = ""
        let t = MoshOrSSHTransport(
            useMosh: true,
            makeCommandRunner: { MockCommandRunner(stdout: "MOSH CONNECT 60008 k==\n") },
            makeSSHTransport: { ssh })   // makeMoshTransport nil
        t.onData = { notice += String(decoding: $0, as: UTF8.self) }
        t.start()
        XCTAssertTrue(ssh.started)
        XCTAssertTrue(notice.contains("isn't built yet"))
    }

    func testForwardsIOToActiveTransport() {
        let ssh = RecordingTransport("ssh")
        var received: [UInt8] = []
        var opened = false
        var closed = false
        let t = MoshOrSSHTransport(
            useMosh: false,
            makeCommandRunner: { MockCommandRunner() },
            makeSSHTransport: { ssh })
        t.onData = { received.append(contentsOf: $0) }
        t.onOpen = { opened = true }
        t.onClose = { _ in closed = true }
        t.start()

        // Input flows down to the active transport.
        t.send(ArraySlice(Array("hi".utf8)))
        XCTAssertEqual(ssh.sent, Array("hi".utf8))
        t.resize(cols: 100, rows: 30)
        XCTAssertEqual(ssh.lastSize?.cols, 100)

        // Output/open/close flow up from the active transport.
        ssh.onOpen?()
        ssh.onData?(ArraySlice(Array("out".utf8)))
        ssh.onClose?(nil)
        XCTAssertTrue(opened)
        XCTAssertEqual(received, Array("out".utf8))
        XCTAssertTrue(closed)
    }
}
