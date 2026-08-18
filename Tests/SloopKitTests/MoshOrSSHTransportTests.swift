// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

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

    /// A command runner that holds its completion until the test releases it,
    /// so the window while `mosh-server` is being probed can be exercised.
    /// `MockCommandRunner` completes synchronously, which closes that window
    /// before a test can reach it.
    private final class DeferredCommandRunner: CommandRunner {
        private var completion: ((Result<CommandResult, Error>) -> Void)?
        func run(_ command: String, completion: @escaping (Result<CommandResult, Error>) -> Void) {
            self.completion = completion
        }
        func finish(stdout: String) {
            completion?(.success(CommandResult(stdout: Data(stdout.utf8),
                                               stderr: Data(), exitStatus: 0)))
        }
    }

    /// Size and keystrokes that arrive while the probe is still running must
    /// reach the transport that ends up carrying the session.
    ///
    /// Choosing Mosh takes a full SSH connect, auth and exec round trip, and
    /// the terminal is live throughout — SwiftTerm reports its geometry in that
    /// window. Dropping it left the remote at mosh's 80×24 default while the
    /// real view was wider, so the server drew frames for the wrong size and
    /// the screen came out garbled. SwiftTerm only reports a size *change*, so
    /// nothing corrects it afterwards.
    func testInputAndResizeDuringTheProbeAreNotLost() {
        let mosh = RecordingTransport("mosh")
        let runner = DeferredCommandRunner()
        let t = MoshOrSSHTransport(
            useMosh: true,
            makeCommandRunner: { runner },
            makeSSHTransport: { RecordingTransport("ssh") },
            makeMoshTransport: { _ in mosh })
        t.start()

        // The probe has not answered yet: this is the window.
        t.resize(cols: 120, rows: 40)
        t.send(ArraySlice(Array("whoami\n".utf8)))
        XCTAssertNil(mosh.lastSize, "nothing should reach a transport that doesn't exist yet")

        runner.finish(stdout: "MOSH CONNECT 60010 key==\n")

        XCTAssertTrue(mosh.started)
        XCTAssertEqual(mosh.lastSize?.cols, 120, "the real terminal size must reach Mosh")
        XCTAssertEqual(mosh.lastSize?.rows, 40)
        XCTAssertEqual(mosh.sent, Array("whoami\n".utf8), "keystrokes typed during the probe must arrive")
    }

    /// Closing the tab while the probe is in flight must not go on to open a
    /// connection afterwards — nobody owns it and nothing will ever close it.
    func testCloseDuringTheProbeNeverActivatesATransport() {
        let mosh = RecordingTransport("mosh")
        let ssh = RecordingTransport("ssh")
        let runner = DeferredCommandRunner()
        let t = MoshOrSSHTransport(
            useMosh: true,
            makeCommandRunner: { runner },
            makeSSHTransport: { ssh },
            makeMoshTransport: { _ in mosh })
        t.start()
        t.close()

        runner.finish(stdout: "MOSH CONNECT 60011 key==\n")

        XCTAssertFalse(mosh.started, "a closed session must not open a Mosh connection")
        XCTAssertFalse(ssh.started, "nor fall back to an SSH one")
    }
}

/// The history import asks the transport to run a command on the connection it
/// already has. It used to ask by casting to the concrete SSH transport, which
/// is exactly what a Mosh-enabled host does not hand back — so on those hosts
/// the import silently did nothing, and the feature looked broken rather than
/// absent.
extension MoshOrSSHTransportTests {
    private final class RunnerTransport: Transport, SessionCommandRunner {
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onOpen: (() -> Void)?
        var onClose: ((Error?) -> Void)?
        private(set) var ranCommand: String?
        func start() {}
        func send(_ bytes: ArraySlice<UInt8>) {}
        func resize(cols: Int, rows: Int) {}
        func close() {}
        func runOnSession(_ command: String, completion: @escaping (String?) -> Void) {
            ranCommand = command
            completion("git status")
        }
    }

    func testForwardsACommandToWhicheverTransportIsLive() {
        let ssh = RunnerTransport()
        let composite = MoshOrSSHTransport(
            useMosh: false,
            makeCommandRunner: { MockCommandRunner() },
            makeSSHTransport: { ssh })
        composite.start()

        var output: String?
        composite.runOnSession("history", completion: { output = $0 })
        XCTAssertEqual(ssh.ranCommand, "history")
        XCTAssertEqual(output, "git status")
    }

    /// A Mosh session's SSH connection existed only long enough to start
    /// mosh-server. Reporting nil is how the caller learns to stop waiting.
    func testReportsNothingWhenTheLiveTransportCannotRunCommands() {
        let mosh = RecordingTransport("mosh")
        let composite = MoshOrSSHTransport(
            useMosh: true,
            makeCommandRunner: { MockCommandRunner(stdout: "MOSH CONNECT 60001 key==\n") },
            makeSSHTransport: { RecordingTransport("ssh") },
            makeMoshTransport: { _ in mosh })
        composite.start()

        var asked = false
        var output: String? = "unset"
        composite.runOnSession("history") { asked = true; output = $0 }
        XCTAssertTrue(asked)
        XCTAssertNil(output)
    }
}
