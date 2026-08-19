// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class MoshLaunchTests: XCTestCase {

    // MARK: interpret()

    func testInterpretConnectBanner() {
        let output = "MOSH CONNECT 60001 x9FkQ2Zt==\n\nmosh-server (mosh 1.4.0)\n"
        XCTAssertEqual(MoshServer.interpret(output),
                       .connect(MoshBootstrap(udpPort: 60001, key: "x9FkQ2Zt==")))
    }

    func testInterpretCommandNotFound() {
        let output = "bash: mosh-server: command not found\n"
        guard case .unavailable(let reason) = MoshServer.interpret(output) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertTrue(reason.contains("isn't installed"))
    }

    func testInterpretNonUTF8Locale() {
        let output = "mosh-server needs a UTF-8 native locale to run.\n"
        guard case .unavailable(let reason) = MoshServer.interpret(output) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertTrue(reason.contains("UTF-8"))
    }

    func testInterpretUnknownGarbage() {
        XCTAssertEqual(MoshServer.interpret("something unexpected\n"),
                       .unavailable(reason: "mosh-server didn't start"))
    }

    // MARK: MoshBootstrapper over a CommandRunner

    func testBootstrapperConnectsWhenServerStarts() {
        let runner = MockCommandRunner(stdout: "MOSH CONNECT 60005 abc123==\n")
        let boot = MoshBootstrapper(runner: runner)
        let exp = expectation(description: "bootstrap")
        boot.bootstrap { startup in
            XCTAssertEqual(startup, .connect(MoshBootstrap(udpPort: 60005, key: "abc123==")))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testBootstrapperFallsBackWhenServerMissing() {
        // A missing mosh-server surfaces as a shell error on stderr.
        let runner = MockCommandRunner(stderr: "bash: mosh-server: command not found\n", exitStatus: 127)
        let boot = MoshBootstrapper(runner: runner)
        let exp = expectation(description: "bootstrap")
        boot.bootstrap { startup in
            guard case .unavailable(let reason) = startup else {
                return XCTFail("expected fallback")
            }
            XCTAssertTrue(reason.contains("isn't installed"))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testBootstrapperFallsBackOnRunnerFailure() {
        let runner = MockCommandRunner(.failure(SSHError.channelFailure("exec failed")))
        let boot = MoshBootstrapper(runner: runner)
        let exp = expectation(description: "bootstrap")
        boot.bootstrap { startup in
            guard case .unavailable = startup else {
                return XCTFail("expected fallback")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}

extension MoshLaunchTests {
    /// A Mosh session's only SSH connection is the one that starts
    /// mosh-server, and it closes before the terminal opens — so the host's
    /// shell history is read on that same command or not at all.
    func testBootstrapCanCarryTheHistoryReadWithIt() {
        let command = MoshServer.bootstrapCommand(includingShellHistory: true)
        XCTAssertTrue(command.hasPrefix(MoshServer.bootstrapCommand),
                      "the server must still be started first")
        XCTAssertTrue(command.contains(".zsh_history"))
    }

    /// Nothing is read for a host that doesn't want suggestions.
    func testBootstrapAloneWhenNoHistoryIsWanted() {
        XCTAssertEqual(MoshServer.bootstrapCommand(includingShellHistory: false),
                       MoshServer.bootstrapCommand)
    }

    func testTheServerBannerAndTheHistoryAreSeparated() {
        let output = """
        MOSH CONNECT 60001 dGhpcyBpcyBhIGtleQ==
        \(MoshServer.historyMarker)
        git status
        make -j8
        """
        let (banner, history) = MoshServer.separateShellHistory(from: output)
        XCTAssertTrue(banner.contains("MOSH CONNECT 60001"))
        XCTAssertFalse(banner.contains("git status"), "history must not reach the banner parser")
        XCTAssertEqual(ShellHistoryImporter.commands(fromHistoryOutput: history ?? ""),
                       ["git status", "make -j8"])
    }

    /// A host with no history files prints nothing after the marker, which is
    /// not the same as a failure.
    func testNoHistoryIsReportedAsNone() {
        let (banner, history) = MoshServer.separateShellHistory(
            from: "MOSH CONNECT 60001 key==\n\(MoshServer.historyMarker)\n\n")
        XCTAssertTrue(banner.contains("MOSH CONNECT"))
        XCTAssertNil(history)
    }

    /// An older server, or a host where the marker never printed, still boots.
    func testOutputWithoutAMarkerIsAllBanner() {
        let (banner, history) = MoshServer.separateShellHistory(from: "MOSH CONNECT 60001 key==")
        XCTAssertEqual(banner, "MOSH CONNECT 60001 key==")
        XCTAssertNil(history)
    }
}
