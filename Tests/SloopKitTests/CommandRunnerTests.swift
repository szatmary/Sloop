import XCTest
@testable import SloopKit

final class CommandRunnerTests: XCTestCase {

    func testCommandResultTextAndSuccess() {
        let ok = CommandResult(stdout: Data("hello\n".utf8), stderr: Data(), exitStatus: 0)
        XCTAssertEqual(ok.stdoutText, "hello\n")
        XCTAssertEqual(ok.stderrText, "")
        XCTAssertTrue(ok.succeeded)

        let bad = CommandResult(stdout: Data(), stderr: Data("nope\n".utf8), exitStatus: 1)
        XCTAssertEqual(bad.stderrText, "nope\n")
        XCTAssertFalse(bad.succeeded)
    }

    func testMockCommandRunnerReturnsCannedResult() {
        let runner = MockCommandRunner(stdout: "uptime output", exitStatus: 0)
        let exp = expectation(description: "run")
        runner.run("uptime") { result in
            switch result {
            case .success(let r):
                XCTAssertEqual(r.stdoutText, "uptime output")
                XCTAssertTrue(r.succeeded)
            case .failure(let error):
                XCTFail("unexpected failure: \(error)")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }

    func testMockCommandRunnerCanReturnFailure() {
        let runner = MockCommandRunner(.failure(SSHError.channelFailure("boom")))
        let exp = expectation(description: "run")
        runner.run("whatever") { result in
            if case .success = result { XCTFail("expected failure") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1)
    }
}
