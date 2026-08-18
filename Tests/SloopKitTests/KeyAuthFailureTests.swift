// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// Measured against a real server: Ed25519, ECDSA and passphrase-protected keys
/// all authenticate through libssh2 over OpenSSL 3. The one client-side failure
/// that came up was a wrong passphrase, which libssh2 reports as
/// `-19 Callback returned error` — true, and useless to the person who mistyped
/// it.
final class KeyAuthFailureTests: XCTestCase {
    func testAWrongPassphraseSaysSo() {
        let message = KeyAuthFailure.message(code: KeyAuthFailure.publicKeyUnverified,
                                             libssh2Message: "Callback returned error",
                                             hasPassphrase: true, username: "root")
        XCTAssertTrue(message.contains("passphrase"))
        XCTAssertFalse(message.contains("Callback"), "libssh2's wording helps nobody here")
    }

    /// The same code with no passphrase stored usually means the key has one
    /// and nobody said so.
    func testAnUnreadableKeyWithNoPassphraseSuggestsOne() {
        let message = KeyAuthFailure.message(code: KeyAuthFailure.publicKeyUnverified,
                                             libssh2Message: "Callback returned error",
                                             hasPassphrase: false, username: "root")
        XCTAssertTrue(message.contains("passphrase"))
    }

    /// Anything else is the server's answer, and libssh2's wording is the most
    /// specific thing available.
    func testOtherFailuresKeepLibssh2sAccount() {
        let message = KeyAuthFailure.message(code: -18,
                                             libssh2Message: "Username/PublicKey combination invalid",
                                             hasPassphrase: false, username: "matt")
        XCTAssertTrue(message.contains("Username/PublicKey combination invalid"))
        XCTAssertTrue(message.contains("matt"))
    }
}
