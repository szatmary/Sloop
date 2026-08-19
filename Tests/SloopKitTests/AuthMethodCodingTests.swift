// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// Pins the on-disk shape of `AuthMethod`.
///
/// `HostStore.load()` decodes the whole array or gives up — one host it cannot
/// read empties the entire list, silently. That makes any change to this
/// enum's encoded form a data-loss change, so the form is pinned here rather
/// than left to Swift's synthesised `Codable` and everyone's good intentions.
final class AuthMethodCodingTests: XCTestCase {

    private func json(_ method: AuthMethod) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(method), as: UTF8.self)
    }

    func testPasswordEncodesAsItsCaseName() throws {
        XCTAssertEqual(try json(.password), #"{"password":{}}"#)
    }

    func testPublicKeyCarriesTheKeyName() throws {
        XCTAssertEqual(try json(.publicKey(name: "id_ed25519")),
                       #"{"publicKey":{"name":"id_ed25519"}}"#)
    }

    func testAHostSavedByAnEarlierBuildStillDecodes() throws {
        let stored = #"""
        {"id":"6C7C1F3E-2E1D-4E2B-9D4E-6D0E5E5B0A11","alias":"prod",\
        "hostname":"example.com","port":22,"username":"matt",\
        "auth":{"password":{}},"useMosh":false}
        """#.replacingOccurrences(of: "\\\n", with: "")

        let host = try JSONDecoder().decode(SSHHost.self, from: Data(stored.utf8))
        XCTAssertEqual(host.alias, "prod")
        XCTAssertEqual(host.auth, .password)
    }

    func testEveryCaseRoundTrips() throws {
        for method in [AuthMethod.password, .publicKey(name: "web")] {
            let decoded = try JSONDecoder().decode(
                AuthMethod.self, from: try JSONEncoder().encode(method))
            XCTAssertEqual(decoded, method)
        }
    }
}
