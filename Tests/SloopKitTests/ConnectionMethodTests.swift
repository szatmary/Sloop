// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class ConnectionMethodTests: XCTestCase {

    /// Only Cloudflare Access rules Mosh out, because TCP-inside-a-WebSocket
    /// has nowhere to put a datagram. A tailnet does — `TailscaleNode.dialUDP`
    /// opens the SSP socket through the same node that carries SSH. The editor
    /// and the connect path both read this; they used to each carry their own
    /// copy and disagree.
    func testOnlyTheWebSocketTunnelRulesOutMosh() {
        XCTAssertTrue(ConnectionMethod.direct.carriesMosh)
        XCTAssertTrue(ConnectionMethod.tailscale.carriesMosh)
        XCTAssertFalse(ConnectionMethod.cloudflareAccess.carriesMosh)
    }

    /// The footnote under a disabled toggle is the only place the user learns
    /// why it's disabled. A method that can't carry Mosh and says nothing looks
    /// like a bug in the app.
    func testEveryMethodThatCannotCarryMoshSaysWhy() {
        for method in ConnectionMethod.allCases {
            if method.carriesMosh {
                XCTAssertNil(method.moshUnavailableReason, "\(method) can carry Mosh")
            } else {
                let reason = method.moshUnavailableReason
                XCTAssertNotNil(reason, "\(method) disables Mosh with no explanation")
                XCTAssertTrue(reason?.contains("UDP") == true,
                              "\(method): the reason is always UDP; say so")
            }
        }
    }

    func testEveryMethodHasADisplayName() {
        for method in ConnectionMethod.allCases {
            XCTAssertFalse(method.displayName.isEmpty)
        }
    }
}
