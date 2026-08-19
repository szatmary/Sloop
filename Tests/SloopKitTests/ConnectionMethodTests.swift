// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class ConnectionMethodTests: XCTestCase {

    /// Mosh's UDP leg never passes through a `Dialer`, so only the direct path
    /// can carry it. The editor and the connect path both read this — they used
    /// to each carry their own copy of the rule, and disagreed: the editor
    /// offered Mosh over Tailscale and the connect path silently ran SSH.
    func testOnlyTheDirectMethodCarriesMosh() {
        XCTAssertTrue(ConnectionMethod.direct.carriesMosh)
        XCTAssertFalse(ConnectionMethod.cloudflareAccess.carriesMosh)
        XCTAssertFalse(ConnectionMethod.tailscale.carriesMosh)
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

    /// A tailnet host *can* run Mosh — over Direct, with the Tailscale app
    /// carrying the route. Telling the user only "no" would send them away from
    /// a combination that works.
    func testTailscaleExplainsHowToGetMoshAnyway() {
        let reason = ConnectionMethod.tailscale.moshUnavailableReason ?? ""
        XCTAssertTrue(reason.contains("Direct"))
        XCTAssertTrue(reason.contains("Tailscale app"))
    }

    func testEveryMethodHasADisplayName() {
        for method in ConnectionMethod.allCases {
            XCTAssertFalse(method.displayName.isEmpty)
        }
    }
}
