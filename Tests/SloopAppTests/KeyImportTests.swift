// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if canImport(CSSH)
import XCTest
import SloopKit
@testable import SloopSSH

/// The pipeline every import path shares. What is pinned here is the policy —
/// what gets refused, what gets stored, and what a collision does — because the
/// point of having one pipeline is that the CLI, the paste field, an SFTP pull
/// and a file picker cannot answer those differently.
final class KeyImportTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    /// A `.pub` line's trailing comment is the *library name*, so it differs
    /// between a fixture and the same key imported under another name. Only the
    /// algorithm and the blob identify the key.
    private func material(_ line: String?) -> String? {
        line.map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
    }

    // MARK: prepare

    func testPreparedKeyCarriesTheDerivedPublicKey() throws {
        let key = try KeyImport.prepare(data(KeyFixtures.ed25519PEM),
                                        name: "fixture-ed25519",
                                        passphrase: nil).get()
        XCTAssertEqual(key.name, "fixture-ed25519")
        XCTAssertEqual(key.publicKey, KeyFixtures.ed25519PublicLine)
        XCTAssertNil(key.passphrase)
    }

    /// The paste field hands over whatever was in the clipboard, so the
    /// surrounding newlines it usually brings must not matter.
    func testPreparedPEMIsTrimmedButOtherwiseUntouched() throws {
        let key = try KeyImport.prepare(data("\n\n  " + KeyFixtures.ed25519PEM + "  \n\n"),
                                        name: "k", passphrase: nil).get()
        XCTAssertEqual(key.privateKeyPEM, KeyFixtures.ed25519PEM)
    }

    func testPreparedKeyKeepsAPassphraseThatWasNeeded() throws {
        let key = try KeyImport.prepare(data(KeyFixtures.ed25519PassphrasePEM),
                                        name: "k",
                                        passphrase: KeyFixtures.passphrase).get()
        XCTAssertEqual(key.passphrase, KeyFixtures.passphrase)
    }

    /// An empty passphrase is not a passphrase, and storing "" would make
    /// `list-keys` claim the key has one.
    func testEmptyPassphraseIsNotStored() throws {
        let key = try KeyImport.prepare(data(KeyFixtures.ed25519PEM),
                                        name: "k", passphrase: "").get()
        XCTAssertNil(key.passphrase)
    }

    // MARK: What it refuses, with the reason intact

    func testAPublicKeyIsRefusedAsSuch() {
        let result = KeyImport.prepare(data(KeyFixtures.ed25519PublicLine),
                                       name: "k", passphrase: nil)
        XCTAssertEqual(result.failure, .rejected(.publicKey))
        XCTAssertTrue(result.failure?.errorDescription?.contains(".pub") == true,
                      "the message should point at the right file to use instead")
    }

    func testAnEncryptedKeyWithNoPassphraseAsksForOne() {
        XCTAssertEqual(KeyImport.prepare(data(KeyFixtures.ed25519PassphrasePEM),
                                         name: "k", passphrase: nil).failure,
                       .needsPassphrase)
    }

    func testAWrongPassphraseSaysSoRatherThanAskingAgain() {
        XCTAssertEqual(KeyImport.prepare(data(KeyFixtures.ed25519PassphrasePEM),
                                         name: "k", passphrase: "wrong").failure,
                       .wrongPassphraseOrUnreadable)
    }

    func testNonKeyInputKeepsItsSpecificRejection() {
        XCTAssertEqual(KeyImport.prepare(Data(), name: "k", passphrase: nil).failure,
                       .rejected(.empty))
        XCTAssertEqual(KeyImport.prepare(data("Host web\n  User matt\n"),
                                         name: "k", passphrase: nil).failure,
                       .rejected(.noPEMEnvelope))
    }

    // MARK: Storing, and the collision policy

    func testImportStoresTheKey() throws {
        let store = InMemoryKeyStore()
        try KeyImport.importKey(data(KeyFixtures.ed25519PEM),
                                name: "work", passphrase: nil, into: store)
        XCTAssertEqual(material(store.key(named: "work")?.publicKey),
                       material(KeyFixtures.ed25519PublicLine))
    }

    /// The library syncs to every device, so an overwrite destroys key material
    /// on machines that are not present to object. Refusing is the policy, and
    /// it is enforced here rather than at each of the four call sites.
    func testACollidingNameIsRefusedNotOverwritten() throws {
        let store = InMemoryKeyStore()
        try KeyImport.importKey(data(KeyFixtures.ed25519PEM),
                                name: "work", passphrase: nil, into: store)

        XCTAssertThrowsError(try KeyImport.importKey(data(KeyFixtures.rsaPEM),
                                                     name: "work", passphrase: nil, into: store)) {
            XCTAssertEqual($0 as? KeyImportError, .nameAlreadyInLibrary("work"))
        }
        // The original survived.
        XCTAssertEqual(material(store.key(named: "work")?.publicKey),
                       material(KeyFixtures.ed25519PublicLine))
    }

    func testForceOverwritesDeliberately() throws {
        let store = InMemoryKeyStore()
        try KeyImport.importKey(data(KeyFixtures.ed25519PEM),
                                name: "work", passphrase: nil, into: store)
        try KeyImport.importKey(data(KeyFixtures.rsaPEM),
                                name: "work", passphrase: nil, into: store, force: true)
        XCTAssertEqual(material(store.key(named: "work")?.publicKey),
                       material(KeyFixtures.rsaPublicLine))
    }

    /// A key that fails validation must not reach the store at all — otherwise
    /// the library accumulates entries that can never authenticate.
    func testNothingIsStoredWhenValidationFails() {
        let store = InMemoryKeyStore()
        XCTAssertThrowsError(try KeyImport.importKey(data("not a key"),
                                                     name: "work", passphrase: nil, into: store))
        XCTAssertTrue(store.keys().isEmpty)
    }
}

private extension Result where Failure == KeyImportError {
    var failure: KeyImportError? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
#endif
