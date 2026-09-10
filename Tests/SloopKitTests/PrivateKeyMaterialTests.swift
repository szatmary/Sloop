// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// Classification is deliberately shallow: it answers "is this plausibly a
/// private key, and what envelope is it in", and nothing about whether the key
/// is encrypted. That question belongs to whoever can actually attempt the
/// parse — guessing it from the envelope is the mistake `KeyCLI.isEncryptedPEM`
/// made. See Docs/superpowers/specs/2026-08-19-key-import-design.md.
final class PrivateKeyMaterialTests: XCTestCase {

    private func pem(_ label: String, body: String = "AAAABBBBCCCC") -> Data {
        Data("-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n".utf8)
    }

    // MARK: Envelopes we accept

    func testRecognizesOpenSSHEnvelope() throws {
        let r = try PrivateKeyMaterial.recognize(pem("OPENSSH PRIVATE KEY")).get()
        XCTAssertEqual(r.envelope, .openssh)
    }

    func testRecognizesPKCS8Envelope() throws {
        let r = try PrivateKeyMaterial.recognize(pem("PRIVATE KEY")).get()
        XCTAssertEqual(r.envelope, .pkcs8)
    }

    func testRecognizesEncryptedPKCS8Envelope() throws {
        let r = try PrivateKeyMaterial.recognize(pem("ENCRYPTED PRIVATE KEY")).get()
        XCTAssertEqual(r.envelope, .pkcs8Encrypted)
    }

    func testRecognizesLegacyRSAAndECAndDSAEnvelopes() throws {
        XCTAssertEqual(try PrivateKeyMaterial.recognize(pem("RSA PRIVATE KEY")).get().envelope, .rsa)
        XCTAssertEqual(try PrivateKeyMaterial.recognize(pem("EC PRIVATE KEY")).get().envelope, .ec)
        XCTAssertEqual(try PrivateKeyMaterial.recognize(pem("DSA PRIVATE KEY")).get().envelope, .dsa)
    }

    /// The PEM handed onward is trimmed but otherwise byte-identical — libssh2
    /// parses the armor itself, so re-wrapping or normalizing it here would be
    /// a chance to corrupt a key for no gain.
    func testPreservesThePEMExactlyApartFromSurroundingWhitespace() throws {
        let body = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA==\n-----END OPENSSH PRIVATE KEY-----"
        let r = try PrivateKeyMaterial.recognize(Data("\n\n  \(body)  \n\n".utf8)).get()
        XCTAssertEqual(r.pem, body)
    }

    /// CRLF is what a key that has been through Windows looks like, and this
    /// feature exists for Windows users.
    func testAcceptsCRLFLineEndings() throws {
        let data = Data("-----BEGIN OPENSSH PRIVATE KEY-----\r\nAAAA\r\n-----END OPENSSH PRIVATE KEY-----\r\n".utf8)
        XCTAssertEqual(try PrivateKeyMaterial.recognize(data).get().envelope, .openssh)
    }

    // MARK: What we refuse, and why it matters that we name it

    func testRejectsEmptyInput() {
        XCTAssertEqual(PrivateKeyMaterial.recognize(Data()).rejection, .empty)
        XCTAssertEqual(PrivateKeyMaterial.recognize(Data("   \n\n".utf8)).rejection, .empty)
    }

    func testRejectsBinary() {
        XCTAssertEqual(PrivateKeyMaterial.recognize(Data([0x00, 0x01, 0x02, 0xFF])).rejection, .notText)
    }

    /// Picking `id_ed25519.pub` instead of `id_ed25519` is the single likeliest
    /// mistake in a file picker, so it gets its own answer rather than a
    /// generic "not a key".
    func testRejectsAPublicKeyLine() {
        let pub = Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample matt@laptop\n".utf8)
        XCTAssertEqual(PrivateKeyMaterial.recognize(pub).rejection, .publicKey)
    }

    func testRejectsEveryPublicKeyAlgorithmWeKnow() {
        for algorithm in ["ssh-rsa", "ssh-dss", "ssh-ed25519",
                          "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                          "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com"] {
            let pub = Data("\(algorithm) AAAAB3NzaC1 comment\n".utf8)
            XCTAssertEqual(PrivateKeyMaterial.recognize(pub).rejection, .publicKey,
                           "expected \(algorithm) to be recognized as a public key")
        }
    }

    func testRejectsKnownHosts() {
        let plain = Data("example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5\n".utf8)
        XCTAssertEqual(PrivateKeyMaterial.recognize(plain).rejection, .knownHosts)

        let hashed = Data("|1|abc=|def= ssh-rsa AAAAB3NzaC1yc2E\n".utf8)
        XCTAssertEqual(PrivateKeyMaterial.recognize(hashed).rejection, .knownHosts)
    }

    func testRejectsArbitraryText() {
        XCTAssertEqual(PrivateKeyMaterial.recognize(Data("Host web\n  User matt\n".utf8)).rejection,
                       .noPEMEnvelope)
    }

    /// A key truncated in transit parses as neither a key nor anything else.
    /// Naming it separately is what lets the UI say "this looks cut off"
    /// instead of sending the user hunting for a passphrase they never set.
    func testRejectsAPEMMissingItsEndLine() {
        let data = Data("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n".utf8)
        XCTAssertEqual(PrivateKeyMaterial.recognize(data).rejection, .truncated)
    }

    // MARK: Default names

    func testDefaultNameIsTheBasename() {
        XCTAssertEqual(PrivateKeyMaterial.defaultName(forPath: "/home/matt/.ssh/id_ed25519"), "id_ed25519")
        XCTAssertEqual(PrivateKeyMaterial.defaultName(forPath: "id_rsa"), "id_rsa")
    }

    func testDefaultNameDropsAKeyBearingExtension() {
        XCTAssertEqual(PrivateKeyMaterial.defaultName(forPath: "~/keys/work.pem"), "work")
        XCTAssertEqual(PrivateKeyMaterial.defaultName(forPath: "work.key"), "work")
    }

    /// Windows paths, because that is who this is for.
    func testDefaultNameHandlesBackslashPaths() {
        XCTAssertEqual(PrivateKeyMaterial.defaultName(forPath: #"C:\Users\matt\.ssh\id_ed25519"#),
                       "id_ed25519")
    }

    func testDefaultNameFallsBackWhenThereIsNothingUsable() {
        XCTAssertEqual(PrivateKeyMaterial.defaultName(forPath: ""), "imported-key")
        XCTAssertEqual(PrivateKeyMaterial.defaultName(forPath: "/"), "imported-key")
    }

    // MARK: The ~/.ssh listing filter

    /// Filtering by name rather than by content is deliberate: classifying by
    /// content would mean pulling every private key in the directory off the
    /// server just to decide what to show.
    func testDirectoryFilterHidesTheKnownNonKeys() {
        for name in ["id_ed25519.pub", "known_hosts", "known_hosts.old", "config",
                     "authorized_keys", "authorized_keys2", "environment", "rc", "."] {
            XCTAssertFalse(PrivateKeyMaterial.mayBePrivateKeyFile(named: name),
                           "expected \(name) to be filtered out")
        }
    }

    func testDirectoryFilterKeepsPlausibleKeys() {
        for name in ["id_ed25519", "id_rsa", "work", "deploy.pem", "id_ecdsa"] {
            XCTAssertTrue(PrivateKeyMaterial.mayBePrivateKeyFile(named: name),
                          "expected \(name) to be offered")
        }
    }
}

private extension Result where Success == PrivateKeyMaterial.Recognized,
                               Failure == PrivateKeyMaterial.Rejection {
    var rejection: PrivateKeyMaterial.Rejection? {
        if case .failure(let r) = self { return r }
        return nil
    }
}
