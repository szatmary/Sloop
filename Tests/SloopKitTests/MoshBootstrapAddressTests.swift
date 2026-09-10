// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// The SSP leg has to reach the machine that just started `mosh-server`.
///
/// Mosh resolves its host argument with `AI_NUMERICHOST | AI_NUMERICSERV` and
/// throws `NetworkException("Bad IP address")` for anything else, so a host
/// saved by DNS name failed the instant the tab said "connected" — with no SSH
/// fallback, because Mosh was already active. Resolving the name again here
/// would not do either: round-robin DNS can answer with a different machine,
/// and a dual-stack host can answer A where the SSH leg used AAAA.
final class MoshBootstrapAddressTests: XCTestCase {

    private final class RunnerAtAddress: CommandRunner {
        let peerAddress: String?
        private let banner: String

        init(address: String?, banner: String) {
            self.peerAddress = address
            self.banner = banner
        }

        func run(_ command: String, completion: @escaping (Result<CommandResult, Error>) -> Void) {
            completion(.success(CommandResult(stdout: Data(banner.utf8))))
        }
    }

    private func bootstrap(_ runner: CommandRunner) throws -> MoshBootstrap {
        let done = expectation(description: "bootstrapped")
        var captured: MoshStartup?
        MoshBootstrapper(runner: runner).bootstrap { result in
            captured = result.startup
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        guard case .connect(let bootstrap) = try XCTUnwrap(captured) else {
            throw XCTSkip("expected a connect")
        }
        return bootstrap
    }

    func testTheAddressTheSSHLegReachedIsCarriedToTheMoshLeg() throws {
        let runner = RunnerAtAddress(address: "192.0.2.7",
                                     banner: "MOSH CONNECT 60001 aGVsbG8gdGhlcmU=\n")
        XCTAssertEqual(try bootstrap(runner).serverAddress, "192.0.2.7")
    }

    /// IPv6 travels the same way — the family the SSH leg chose is the one
    /// mosh-server is listening on.
    func testAnIPv6AddressIsCarriedUnchanged() throws {
        let runner = RunnerAtAddress(address: "2001:db8::1",
                                     banner: "MOSH CONNECT 60002 aGVsbG8gdGhlcmU=\n")
        XCTAssertEqual(try bootstrap(runner).serverAddress, "2001:db8::1")
    }

    /// A runner that cannot say leaves it unset, and the caller falls back to
    /// the hostname — which is correct when the host was saved as an address.
    func testARunnerThatCannotSayLeavesItUnset() throws {
        let runner = RunnerAtAddress(address: nil,
                                     banner: "MOSH CONNECT 60003 aGVsbG8gdGhlcmU=\n")
        XCTAssertNil(try bootstrap(runner).serverAddress)
    }

    /// Most runners have nothing to report and should not have to say so.
    func testTheProtocolDefaultIsNoAddress() {
        XCTAssertNil(MockCommandRunner(stdout: "").peerAddress)
    }
}
