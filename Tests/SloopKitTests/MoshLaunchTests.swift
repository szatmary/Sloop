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
