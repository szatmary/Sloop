// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class ForwardedKeysTests: XCTestCase {
    private func host(forwarding names: [String] = []) -> SSHHost {
        var host = SSHHost(alias: "a", hostname: "h", username: "u")
        host.forwardedKeys = names
        return host
    }

    func testForwardingIsOffByDefault() {
        XCTAssertEqual(SSHHost(alias: "a", hostname: "h", username: "u").forwardedKeys, [])
        XCTAssertFalse(SSHHost(alias: "a", hostname: "h", username: "u").forwardsAgent)
    }

    func testSelectingAKeyTurnsForwardingOn() {
        XCTAssertTrue(host(forwarding: ["id_ed25519"]).forwardsAgent)
    }

    /// Host files written before this field existed must still decode, and
    /// must decode as "not forwarding" rather than failing. HostStore keeps
    /// records it cannot decode, but a whole-fleet decode failure here would
    /// hide every host behind a bug of our own making.
    func testHostWrittenBeforeThisFieldDecodesWithForwardingOff() throws {
        let json = """
        {"id":"\(UUID().uuidString)","alias":"a","hostname":"h","port":22,
         "username":"u","auth":{"password":{}},"useMosh":false}
        """
        let decoded = try JSONDecoder().decode(SSHHost.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.forwardedKeys, [])
    }

    func testForwardedKeysRoundTrip() throws {
        let original = host(forwarding: ["a", "b"])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(SSHHost.self, from: data).forwardedKeys, ["a", "b"])
    }

    func testResolvesSelectedNamesToLibraryKeys() throws {
        let store = InMemoryKeyStore()
        try store.setKey(NamedKey(name: "a", privateKeyPEM: "PEM-A"))
        try store.setKey(NamedKey(name: "b", privateKeyPEM: "PEM-B"))

        let resolved = try KeyLibrary.forwardedKeys(for: host(forwarding: ["b"]), keys: store)
        XCTAssertEqual(resolved.map(\.name), ["b"])
        XCTAssertEqual(resolved.first?.privateKeyPEM, "PEM-B")
    }

    /// Selection order is the user's, and the identity list a remote sees
    /// should follow it rather than the store's alphabetical order.
    func testResolvedKeysFollowSelectionOrderNotStoreOrder() throws {
        let store = InMemoryKeyStore()
        try store.setKey(NamedKey(name: "a", privateKeyPEM: "PEM-A"))
        try store.setKey(NamedKey(name: "b", privateKeyPEM: "PEM-B"))

        XCTAssertEqual(try KeyLibrary.forwardedKeys(for: host(forwarding: ["b", "a"]),
                                                    keys: store).map(\.name),
                       ["b", "a"])
    }

    /// A name with no key behind it is dropped, not fatal. The key may have
    /// been deleted from the library after the host was configured, and that
    /// must not make the host unusable — it forwards what still exists.
    func testMissingKeyNamesAreDropped() throws {
        let store = InMemoryKeyStore()
        try store.setKey(NamedKey(name: "a", privateKeyPEM: "PEM-A"))

        XCTAssertEqual(try KeyLibrary.forwardedKeys(for: host(forwarding: ["a", "gone"]),
                                                    keys: store).map(\.name),
                       ["a"])
    }
}
