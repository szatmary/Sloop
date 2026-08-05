import XCTest
@testable import SloopKit

final class HostKeyVerifierTests: XCTestCase {

    func testAutoAcceptTrustsEverything() {
        let verifier = AutoAcceptHostKeyVerifier()
        XCTAssertTrue(verifier.shouldTrust(endpoint: "example.com:22",
                                           keyType: "ssh-ed25519",
                                           fingerprint: "AAAA"))
    }

    func testClosureVerifierCanRefuse() {
        let deny = ClosureHostKeyVerifier { _, _, _ in false }
        XCTAssertFalse(deny.shouldTrust(endpoint: "e", keyType: "k", fingerprint: "f"))
    }

    func testClosureVerifierReceivesEndpoint() {
        var seen: String?
        let verifier = ClosureHostKeyVerifier { endpoint, _, _ in
            seen = endpoint
            return true
        }
        XCTAssertTrue(verifier.shouldTrust(endpoint: "host:2222",
                                           keyType: "ssh-rsa",
                                           fingerprint: "x"))
        XCTAssertEqual(seen, "host:2222")
    }
}
