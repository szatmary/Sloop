// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
// The macOS app target is named Sloop_macOS, so its module is Sloop_macOS.
@testable import Sloop_macOS
@testable import SloopSSH
import SloopKit

#if canImport(CSSH)
import CSSH

final class AgentSignerTests: XCTestCase {
    private var session: OpaquePointer!

    override func setUpWithError() throws {
        XCTAssertEqual(libssh2_init(0), 0)
        session = libssh2_session_init_ex(nil, nil, nil, nil)
        XCTAssertNotNil(session)
    }

    override func tearDownWithError() throws {
        if let session { libssh2_session_free(session) }
        libssh2_exit()
    }

    /// Writes a real key with ssh-keygen and returns its PEM.
    private func generateKey(type: String, bits: String? = nil) throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("key")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var args = ["-q", "-t", type, "-N", "", "-C", "test", "-f", path.path]
        if let bits { args += ["-b", bits] }
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "ssh-keygen failed for \(type)")

        return try String(contentsOf: path, encoding: .utf8)
    }

    private func signer(pem: String, name: String = "k") -> AgentSigner {
        AgentSigner(session: session, keys: [NamedKey(name: name, privateKeyPEM: pem)])
    }

    func testDerivesAnIdentityWithoutAStoredPublicKey() throws {
        // The iOS import path stores no .pub; the blob must come from the
        // private key alone or forwarding exposes nothing on iPad.
        let signer = signer(pem: try generateKey(type: "ed25519"))
        XCTAssertEqual(signer.identities.count, 1)
        XCTAssertEqual(signer.identities.first?.algorithm, "ssh-ed25519")
        XCTAssertFalse(signer.identities.first?.blob.isEmpty ?? true)
        XCTAssertEqual(signer.identities.first?.keyName, "k")
    }

    func testEd25519SignatureVerifies() throws {
        let signer = signer(pem: try generateKey(type: "ed25519"))
        let identity = try XCTUnwrap(signer.identities.first)
        let message = Array("challenge".utf8)

        let (algorithm, signature) = try signer.sign(identity: identity, data: message, flags: 0)
        XCTAssertEqual(algorithm, "ssh-ed25519")
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(signer.verifyForTesting(identity: identity, signature: signature, message: message))
    }

    func testRSASignatureVerifiesForBothSHA2Sizes() throws {
        let signer = signer(pem: try generateKey(type: "rsa", bits: "2048"))
        let identity = try XCTUnwrap(signer.identities.first)
        let message = Array("challenge".utf8)

        for (flag, expected) in [(AgentSignFlags.rsaSHA2_256, "rsa-sha2-256"),
                                 (AgentSignFlags.rsaSHA2_512, "rsa-sha2-512")] {
            let (algorithm, signature) = try signer.sign(identity: identity, data: message, flags: flag)
            XCTAssertEqual(algorithm, expected)
            XCTAssertTrue(signer.verifyForTesting(identity: identity, signature: signature,
                                                  message: message, flags: flag))
        }
    }

    func testECDSASignatureVerifies() throws {
        let signer = signer(pem: try generateKey(type: "ecdsa", bits: "256"))
        let identity = try XCTUnwrap(signer.identities.first)
        let message = Array("challenge".utf8)

        let (algorithm, signature) = try signer.sign(identity: identity, data: message, flags: 0)
        XCTAssertEqual(algorithm, "ecdsa-sha2-nistp256")
        XCTAssertTrue(signer.verifyForTesting(identity: identity, signature: signature, message: message))
    }

    /// Bare ssh-rsa is SHA-1 signed and rejected by OpenSSH 8.8+. There is no
    /// reason for a 2026 client to have that code path at all.
    func testRSAWithNoSHA2FlagIsRefused() throws {
        let signer = signer(pem: try generateKey(type: "rsa", bits: "2048"))
        let identity = try XCTUnwrap(signer.identities.first)
        XCTAssertThrowsError(try signer.sign(identity: identity,
                                             data: Array("x".utf8), flags: 0))
    }

    func testUnknownBlobMatchesNothing() throws {
        let signer = signer(pem: try generateKey(type: "ed25519"))
        XCTAssertNil(signer.identity(matching: [0x00, 0x01, 0x02]))
    }

    func testMatchingIsByExactBlob() throws {
        let signer = signer(pem: try generateKey(type: "ed25519"))
        let identity = try XCTUnwrap(signer.identities.first)
        XCTAssertEqual(signer.identity(matching: identity.blob)?.keyName, "k")
    }

    /// `identity(matching:)` decides which private key signs a remote's
    /// challenge, and the confirmation prompt names whatever key it picks. A
    /// prefix match here would let a crafted, truncated blob select a key the
    /// user never intended — and the prompt naming that wrong key would not
    /// catch it either. A strict prefix of the real blob must not match.
    func testBlobThatIsAStrictPrefixOfTheRealBlobDoesNotMatch() throws {
        let signer = signer(pem: try generateKey(type: "ed25519"))
        let identity = try XCTUnwrap(signer.identities.first)
        let prefix = Array(identity.blob.dropLast())
        XCTAssertFalse(prefix.isEmpty,
                       "the real blob must have more than one byte for this test to mean anything")
        XCTAssertNil(signer.identity(matching: prefix))
    }

    /// The other half of exactness: the real blob with bytes appended must
    /// not match either. Together with the prefix test above, this rules out
    /// both directions `starts(with:)` could be substituted for `==`.
    func testBlobWithTrailingBytesAppendedDoesNotMatch() throws {
        let signer = signer(pem: try generateKey(type: "ed25519"))
        let identity = try XCTUnwrap(signer.identities.first)
        let extended = identity.blob + [0xFF]
        XCTAssertNil(signer.identity(matching: extended))
    }

    /// If both SHA-2 flags are set, SHA-512 must win — silently downgrading to
    /// SHA-256 would still verify but is a weaker signature than the request
    /// asked for. No other test sets both flags at once.
    func testRSAWithBothSHA2FlagsSetPrefersSHA512() throws {
        let signer = signer(pem: try generateKey(type: "rsa", bits: "2048"))
        let identity = try XCTUnwrap(signer.identities.first)
        let message = Array("challenge".utf8)
        let bothFlags = AgentSignFlags.rsaSHA2_256 | AgentSignFlags.rsaSHA2_512

        let (algorithm, signature) = try signer.sign(identity: identity, data: message, flags: bothFlags)
        XCTAssertEqual(algorithm, "rsa-sha2-512")
        XCTAssertTrue(signer.verifyForTesting(identity: identity, signature: signature,
                                              message: message, flags: bothFlags))
    }
}
#endif
