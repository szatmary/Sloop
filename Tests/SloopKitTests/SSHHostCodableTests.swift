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

    /// Every field set to a non-default value on purpose: the synthesized
    /// encoder uses `encodeIfPresent` for the optional `onConnectCommand`, so
    /// a `nil` value emits no key at all — meaning a decode that silently
    /// left it `nil` (e.g. because it had been dropped from `CodingKeys`,
    /// exactly the mistake caught by hand during the recent merge) would
    /// still pass `XCTAssertEqual` against a host built with the default
    /// `nil`. Only a non-nil value round-tripping correctly actually proves
    /// the key survives encode/decode; `port` and `useMosh` get the same
    /// treatment so this doesn't merely re-confirm their own defaults either.
    func testRoundTripsCloudflareAccess() throws {
        let host = SSHHost(alias: "tunnel", hostname: "ssh.example.com",
                           port: 2222, username: "matt",
                           useMosh: true,
                           connectionMethod: .cloudflareAccess,
                           onConnectCommand: "tmux attach || tmux new")
        let data = try JSONEncoder().encode(host)
        let back = try JSONDecoder().decode(SSHHost.self, from: data)
        XCTAssertEqual(back, host)
        XCTAssertEqual(back.connectionMethod, .cloudflareAccess)
        XCTAssertEqual(back.onConnectCommand, "tmux attach || tmux new")
        XCTAssertEqual(back.port, 2222)
        XCTAssertTrue(back.useMosh)
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
