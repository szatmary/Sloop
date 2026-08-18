// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// Recognising a tailnet address is what tells a Tailscale host "Tailscale
/// isn't connected" instead of letting it fail later as a name lookup or a
/// timeout. Getting the range wrong in either direction is silent: too narrow
/// and a connected device is told it isn't, too wide and an ordinary LAN
/// address passes for a tailnet.
final class TailnetPresenceTests: XCTestCase {
    func testAddressesInsideTailscalesRange() {
        // 100.64.0.0/10 — the whole block Tailscale assigns from.
        XCTAssertTrue(TailnetPresence.isTailnetAddress("100.64.0.1"))
        XCTAssertTrue(TailnetPresence.isTailnetAddress("100.101.102.103"))
        XCTAssertTrue(TailnetPresence.isTailnetAddress("100.127.255.254"))
        // Tailscale's IPv6 ULA prefix, in either case.
        XCTAssertTrue(TailnetPresence.isTailnetAddress("fd7a:115c:a1e0::1"))
        XCTAssertTrue(TailnetPresence.isTailnetAddress("FD7A:115C:A1E0:AB12:4843:CD96:6262:0102"))
    }

    func testAddressesOutsideIt() {
        // The neighbours on either side of the /10 — the boundaries are the
        // part of a CIDR check that actually goes wrong.
        XCTAssertFalse(TailnetPresence.isTailnetAddress("100.63.255.255"))
        XCTAssertFalse(TailnetPresence.isTailnetAddress("100.128.0.1"))
        // Ordinary addresses a device really does hold at the same time.
        XCTAssertFalse(TailnetPresence.isTailnetAddress("192.168.0.6"))
        XCTAssertFalse(TailnetPresence.isTailnetAddress("10.0.0.1"))
        XCTAssertFalse(TailnetPresence.isTailnetAddress("127.0.0.1"))
        XCTAssertFalse(TailnetPresence.isTailnetAddress("fe80::1"))
        // Not an address at all.
        XCTAssertFalse(TailnetPresence.isTailnetAddress("100.64"))
        XCTAssertFalse(TailnetPresence.isTailnetAddress("100.64.0.256"))
        XCTAssertFalse(TailnetPresence.isTailnetAddress(""))
    }

    /// The real check must run without crashing and agree with itself; what it
    /// answers depends on whether this machine is on a tailnet.
    func testLocalCheckIsStable() {
        XCTAssertEqual(TailnetPresence.isConnected, TailnetPresence.isConnected)
    }
}
