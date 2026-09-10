// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import Sloop_macOS
@testable import SloopSSH

final class KeyCLITests: XCTestCase {
    func testParsesImportKeyWithDefaultName() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "/Users/m/.ssh/id_ed25519"]),
                       .importKey(path: "/Users/m/.ssh/id_ed25519", name: nil, force: false))
    }

    func testParsesImportKeyWithExplicitName() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--name", "work"]),
                       .importKey(path: "k.pem", name: "work", force: false))
    }

    func testParsesForceAfterName() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--name", "work", "--force"]),
                       .importKey(path: "k.pem", name: "work", force: true))
    }

    func testParsesForceBeforeName() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--force", "--name", "work"]),
                       .importKey(path: "k.pem", name: "work", force: true))
    }

    func testParsesForceWithoutName() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--force"]),
                       .importKey(path: "k.pem", name: nil, force: true))
    }

    func testParsesListAndRemove() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "list-keys"]), .listKeys)
        XCTAssertEqual(KeyCLI.parse(["Sloop", "remove-key", "work"]), .removeKey(name: "work"))
    }

    func testNoSubcommandMeansGUILaunch() {
        XCTAssertNil(KeyCLI.parse(["Sloop"]))
        // Real app launches carry Apple flags like -NSDocumentRevisionsDebugMode;
        // anything that isn't a known subcommand must fall through to the GUI.
        XCTAssertNil(KeyCLI.parse(["Sloop", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testMalformedSubcommandsAreRejectedNotIgnored() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key"]), .usage)
        XCTAssertEqual(KeyCLI.parse(["Sloop", "remove-key"]), .usage)
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--name"]), .usage)
        // --name with a value that happens to look like another flag is
        // still consumed as the name, not re-parsed as a flag; only a
        // trailing --name with nothing after it is malformed (covered
        // above). An unrecognized flag is malformed, not silently ignored.
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--bogus"]), .usage)
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--force", "--name"]), .usage)
    }

    // Encrypted-PEM detection used to be tested here, against
    // `KeyCLI.isEncryptedPEM`. Both are gone: the CLI no longer infers whether
    // a key is encrypted from its envelope, it attempts the parse and prompts
    // when libssh2 refuses. The cases that matter now live in
    // KeyValidatorTests, measured against real ssh-keygen output rather than
    // against hand-written base64 that only had to satisfy the heuristic.
}
