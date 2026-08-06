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

    func testChangedKeyRefusedByDefault() {
        // AutoAccept trusts new keys but must NOT silently accept a changed one —
        // the protocol default refuses.
        let verifier = AutoAcceptHostKeyVerifier()
        XCTAssertFalse(verifier.shouldTrustChangedKey(endpoint: "example.com:22",
                                                      keyType: "ssh-ed25519",
                                                      fingerprint: "NEW",
                                                      previousFingerprint: "OLD"))
    }

    func testClosureVerifierChangedKeyDefaultsRefuse() {
        // A closure verifier built with only the unknown-key closure refuses
        // changed keys.
        let verifier = ClosureHostKeyVerifier { _, _, _ in true }
        XCTAssertFalse(verifier.shouldTrustChangedKey(endpoint: "e", keyType: "k",
                                                      fingerprint: "new", previousFingerprint: "old"))
    }

    func testClosureVerifierCanAcceptChangedKey() {
        var seenPrevious: String?
        let verifier = ClosureHostKeyVerifier(onUnknown: { _, _, _ in false },
                                              onChanged: { _, _, _, previous in
            seenPrevious = previous
            return true
        })
        XCTAssertTrue(verifier.shouldTrustChangedKey(endpoint: "e", keyType: "k",
                                                     fingerprint: "new", previousFingerprint: "old"))
        XCTAssertEqual(seenPrevious, "old")
        // The unknown-key path still refuses independently.
        XCTAssertFalse(verifier.shouldTrust(endpoint: "e", keyType: "k", fingerprint: "f"))
    }
}
