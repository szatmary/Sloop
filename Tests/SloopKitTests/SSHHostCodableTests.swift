// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class SSHHostCodableTests: XCTestCase {

    /// Hosts saved before connectionMethod existed must decode as .direct —
    /// a decode failure here would wipe the user's whole host list.
    func testLegacyJSONDecodesAsDirect() throws {
        let legacy = """
        {"id":"6F1E2D3C-0000-0000-0000-000000000001","alias":"box",
         "hostname":"box.example.com","port":22,"username":"matt",
         "auth":{"password":{}},"useMosh":false}
        """
        let host = try JSONDecoder().decode(SSHHost.self, from: Data(legacy.utf8))
        XCTAssertEqual(host.connectionMethod, .direct)
        XCTAssertEqual(host.alias, "box")
    }

    func testRoundTripsCloudflareAccess() throws {
        let host = SSHHost(alias: "tunnel", hostname: "ssh.example.com",
                           username: "matt", connectionMethod: .cloudflareAccess)
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(SSHHost.self, from: data)
        XCTAssertEqual(back, host)
        XCTAssertEqual(back.connectionMethod, .cloudflareAccess)
    }

    /// A method this build doesn't know must FAIL to decode (Task 3 makes the
    /// store skip such hosts instead of silently connecting them directly).
    func testUnknownMethodThrows() {
        let future = """
        {"id":"6F1E2D3C-0000-0000-0000-000000000002","alias":"x",
         "hostname":"h","port":22,"username":"u","auth":{"password":{}},
         "useMosh":false,"connectionMethod":"wireguard"}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(SSHHost.self, from: Data(future.utf8)))
    }
}
