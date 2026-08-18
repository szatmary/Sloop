// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class KeyStoreTests: XCTestCase {
    private let ed25519 = NamedKey(name: "id_ed25519",
                                   privateKeyPEM: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----",
                                   passphrase: nil)

    func testSetGetRemoveRoundTrip() throws {
        let store = InMemoryKeyStore()
        XCTAssertNil(store.key(named: "id_ed25519"))
        try store.setKey(ed25519)
        XCTAssertEqual(store.key(named: "id_ed25519"), ed25519)
        try store.removeKey(named: "id_ed25519")
        XCTAssertNil(store.key(named: "id_ed25519"))
    }

    func testSetKeyWithSameNameReplaces() throws {
        let store = InMemoryKeyStore()
        try store.setKey(ed25519)
        var updated = ed25519
        updated.passphrase = "secret"
        try store.setKey(updated)
        XCTAssertEqual(store.keys().count, 1)
        XCTAssertEqual(store.key(named: "id_ed25519")?.passphrase, "secret")
    }

    func testKeysAreSortedByName() throws {
        let store = InMemoryKeyStore()
        try store.setKey(NamedKey(name: "work", privateKeyPEM: "pem-b", passphrase: nil))
        try store.setKey(ed25519)
        XCTAssertEqual(store.keys().map(\.name), ["id_ed25519", "work"])
    }

    func testRemoveMissingKeyDoesNotThrow() {
        XCTAssertNoThrow(try InMemoryKeyStore().removeKey(named: "absent"))
    }

    // NamedKey's JSON is the wire format synced across devices via iCloud
    // Keychain (KeychainKeyStore stores the JSON-encoded value directly). A
    // property rename or CodingKeys change here would silently orphan every
    // already-synced item on other devices — decode would just fail and
    // `keys()`/`key(named:)` would quietly drop them (both use `try?`). This
    // test exists to make that kind of change loud, not to test
    // Foundation's JSONEncoder/Decoder themselves.
    func testNamedKeyRoundTripsThroughJSON() throws {
        let key = NamedKey(name: "work", privateKeyPEM: ed25519.privateKeyPEM, passphrase: "secret")
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(NamedKey.self, from: data)
        XCTAssertEqual(decoded, key)
    }

    func testNamedKeyRoundTripsThroughJSONWithNilPassphrase() throws {
        let key = NamedKey(name: "work", privateKeyPEM: "pem-body", passphrase: nil)
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(NamedKey.self, from: data)
        XCTAssertEqual(decoded, key)
        XCTAssertNil(decoded.passphrase)
    }
}
