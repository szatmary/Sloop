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
        boot.bootstrap { result in
            XCTAssertEqual(result.startup, .connect(MoshBootstrap(udpPort: 60005, key: "abc123==")))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testBootstrapperFallsBackWhenServerMissing() {
        // A missing mosh-server surfaces as a shell error on stderr.
        let runner = MockCommandRunner(stderr: "bash: mosh-server: command not found\n", exitStatus: 127)
        let boot = MoshBootstrapper(runner: runner)
        let exp = expectation(description: "bootstrap")
        boot.bootstrap { result in
            guard case .unavailable(let reason) = result.startup else {
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
        boot.bootstrap { result in
            guard case .unavailable = result.startup else {
                return XCTFail("expected fallback")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}

/// A Mosh session's only SSH connection is the one that starts `mosh-server`,
/// and it closes before the terminal opens — so anything else this host is
/// going to be asked has to be asked on that same command, or not at all.
extension MoshLaunchTests {
    func testTheServerIsStartedBeforeAnythingElseIsAsked() {
        let script = MoshServer.script(extraCommands: ["echo hi"])
        XCTAssertTrue(script.hasPrefix(MoshServer.bootstrapCommand))
    }

    /// Nothing to ask means nothing appended: a host whose session wants no
    /// questions answered runs the bare bootstrap.
    func testTheBootstrapRunsAloneWhenNothingElseIsAsked() {
        XCTAssertEqual(MoshServer.script(extraCommands: []), MoshServer.bootstrapCommand)
    }

    func testEachExtraCommandsOutputComesBackWithTheStartup() {
        let runner = MockCommandRunner(stdout: """
            MOSH CONNECT 60001 key==
            \(MarkedCommandBatch.marker(0))
            git status
            \(MarkedCommandBatch.marker(1))
            /home/matt
            """)
        let boot = MoshBootstrapper(runner: runner)
        boot.extraCommands = ["history", "pwd"]

        let exp = expectation(description: "bootstrap")
        boot.bootstrap { result in
            XCTAssertEqual(result.startup, .connect(MoshBootstrap(udpPort: 60001, key: "key==")))
            XCTAssertEqual(result.extraOutputs, ["git status", "/home/matt"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    /// stderr is the bootstrap's: a missing binary is a shell error, and that is
    /// what tells `interpret` Mosh isn't there. It is emphatically *not* part of
    /// the last command's output — appending it there is how a warning from the
    /// remote's login shell ended up being parsed as somebody's command history.
    func testStderrReachesTheBannerAndNotTheLastCommandsOutput() {
        let runner = MockCommandRunner(
            stdout: "MOSH CONNECT 60001 key==\n\(MarkedCommandBatch.marker(0))\ngit status\n",
            stderr: "Warning: no access to tty\n")
        let boot = MoshBootstrapper(runner: runner)
        boot.extraCommands = ["history"]

        let exp = expectation(description: "bootstrap")
        boot.bootstrap { result in
            XCTAssertEqual(result.extraOutputs, ["git status"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    /// Every command gets an answer, even when there was never a connection to
    /// ask on. A caller waiting on a completion that never fires waits forever.
    func testEveryExtraCommandIsAnsweredWhenTheRunnerFails() {
        let runner = MockCommandRunner(.failure(SSHError.channelFailure("exec failed")))
        let boot = MoshBootstrapper(runner: runner)
        boot.extraCommands = ["history", "pwd"]

        let exp = expectation(description: "bootstrap")
        boot.bootstrap { result in
            XCTAssertEqual(result.extraOutputs.count, 2)
            XCTAssertTrue(result.extraOutputs.allSatisfy { $0 == nil })
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}
