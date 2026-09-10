// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if canImport(CSSH)
import XCTest
@testable import SloopSSH

/// The point of these is that the expected `.pub` lines come from `ssh-keygen`
/// itself, not from us. A validator that agrees with its own encoder proves
/// nothing; this project has already shipped a crypto backend that handled RSA
/// and could not parse Ed25519 at all.
final class KeyValidatorTests: XCTestCase {

    private func validated(_ pem: String,
                           passphrase: String? = nil,
                           name: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> KeyValidator.Validated {
        switch KeyValidator.validate(pem: pem, passphrase: passphrase, name: name) {
        case .success(let v): return v
        case .failure(let e): XCTFail("expected success, got \(e)", file: file, line: line); throw e
        }
    }

    // MARK: The gate — validation without ever opening a connection

    /// `_libssh2_pub_priv_keyfilememory` is called with a session that was
    /// created and never connected. If this fails, offline validation is not
    /// possible and the whole import design needs a different primitive.
    func testValidatesWithoutAConnection() throws {
        let v = try validated(KeyFixtures.ed25519PEM, name: "fixture-ed25519")
        XCTAssertEqual(v.algorithm, "ssh-ed25519")
    }

    // MARK: Every key type, against ssh-keygen's own public line

    func testEd25519PublicLineMatchesSSHKeygen() throws {
        let v = try validated(KeyFixtures.ed25519PEM, name: "fixture-ed25519")
        XCTAssertEqual(v.publicKeyLine, KeyFixtures.ed25519PublicLine)
    }

    func testECDSAPublicLineMatchesSSHKeygen() throws {
        let v = try validated(KeyFixtures.ecdsaPEM, name: "fixture-ecdsa")
        XCTAssertEqual(v.algorithm, "ecdsa-sha2-nistp256")
        XCTAssertEqual(v.publicKeyLine, KeyFixtures.ecdsaPublicLine)
    }

    func testRSAPublicLineMatchesSSHKeygen() throws {
        let v = try validated(KeyFixtures.rsaPEM, name: "fixture-rsa")
        XCTAssertEqual(v.algorithm, "ssh-rsa")
        XCTAssertEqual(v.publicKeyLine, KeyFixtures.rsaPublicLine)
    }

    // MARK: Passphrases

    func testPassphraseProtectedKeyValidatesWithTheRightPassphrase() throws {
        let v = try validated(KeyFixtures.ed25519PassphrasePEM,
                              passphrase: KeyFixtures.passphrase,
                              name: "fixture-ed25519-pw")
        XCTAssertEqual(v.publicKeyLine, KeyFixtures.ed25519PassphrasePublicLine)
    }

    /// This is the case `isEncryptedPEM` was guessing at. No heuristic runs
    /// here: the parse is attempted, it fails, and the absence of a supplied
    /// passphrase is what turns that into "ask for one".
    func testEncryptedKeyWithoutAPassphraseAsksForOne() {
        let result = KeyValidator.validate(pem: KeyFixtures.ed25519PassphrasePEM,
                                           passphrase: nil,
                                           name: "k")
        XCTAssertEqual(result.failure, .needsPassphrase)
    }

    /// The same question as above, asked of the *other* container format.
    ///
    /// libssh2 decrypts an OpenSSH container itself and only consults the
    /// passphrase callback when it has one. A legacy `Proc-Type: 4,ENCRYPTED`
    /// PEM goes to OpenSSL's `PEM_read_bio_PrivateKey`, which invokes the
    /// callback regardless — so passing NULL for "no passphrase" reached
    /// `strlen(NULL)` and killed the process. Every import path validates with
    /// no passphrase first, which made this reachable from a plain
    /// `ssh-keygen -m PEM` key.
    func testEncryptedLegacyPEMWithoutAPassphraseAsksForOne() {
        let result = KeyValidator.validate(pem: KeyFixtures.rsaLegacyEncryptedPEM,
                                           passphrase: nil,
                                           name: "k")
        XCTAssertEqual(result.failure, .needsPassphrase)
    }

    /// Control for the test above: the fixture is a real key that parses, so a
    /// crash there cannot be blamed on a malformed fixture.
    func testEncryptedLegacyPEMValidatesWithTheRightPassphrase() throws {
        let v = try validated(KeyFixtures.rsaLegacyEncryptedPEM,
                              passphrase: KeyFixtures.passphrase,
                              name: "fixture-rsa-legacy-pw")
        XCTAssertEqual(v.algorithm, "ssh-rsa")
        XCTAssertEqual(v.publicKeyLine, KeyFixtures.rsaLegacyEncryptedPublicLine)
    }

    func testWrongPassphraseIsReportedAsSuch() {
        let result = KeyValidator.validate(pem: KeyFixtures.ed25519PassphrasePEM,
                                           passphrase: "not-the-passphrase",
                                           name: "k")
        XCTAssertEqual(result.failure, .wrongPassphraseOrUnreadable)
    }

    /// An empty passphrase means "none", not "the empty passphrase" — so this
    /// must land on `.needsPassphrase` and prompt, not on the wrong-passphrase
    /// message.
    func testEmptyPassphraseIsTreatedAsNone() {
        let result = KeyValidator.validate(pem: KeyFixtures.ed25519PassphrasePEM,
                                           passphrase: "",
                                           name: "k")
        XCTAssertEqual(result.failure, .needsPassphrase)
    }

    /// A key that does not need one is not broken by supplying one.
    func testUnencryptedKeyStillValidatesWithAStrayPassphrase() throws {
        let v = try validated(KeyFixtures.ed25519PEM, passphrase: "ignored", name: "fixture-ed25519")
        XCTAssertEqual(v.publicKeyLine, KeyFixtures.ed25519PublicLine)
    }

    // MARK: Damaged input

    func testTruncatedKeyIsRefused() {
        let truncated = String(KeyFixtures.ed25519PEM.prefix(120)) + "\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertNotNil(KeyValidator.validate(pem: truncated, passphrase: nil, name: "k").failure)
    }

    func testGarbageInsideAValidEnvelopeIsRefused() {
        let garbage = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        bm90IGEga2V5IGF0IGFsbA==
        -----END OPENSSH PRIVATE KEY-----
        """
        XCTAssertNotNil(KeyValidator.validate(pem: garbage, passphrase: nil, name: "k").failure)
    }

    /// The name is the comment field and nothing more — it must not change how
    /// the key itself is read.
    func testNameOnlyAffectsTheCommentField() throws {
        let a = try validated(KeyFixtures.ed25519PEM, name: "one")
        let b = try validated(KeyFixtures.ed25519PEM, name: "two")
        XCTAssertEqual(a.publicKeyLine.split(separator: " ").prefix(2),
                       b.publicKeyLine.split(separator: " ").prefix(2))
        XCTAssertTrue(a.publicKeyLine.hasSuffix(" one"))
        XCTAssertTrue(b.publicKeyLine.hasSuffix(" two"))
    }
}

private extension Result where Failure == KeyValidator.Failure {
    var failure: KeyValidator.Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
#endif
