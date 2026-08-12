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
}
