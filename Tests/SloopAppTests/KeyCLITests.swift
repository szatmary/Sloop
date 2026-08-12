import XCTest
@testable import Sloop_macOS

final class KeyCLITests: XCTestCase {
    func testParsesImportKeyWithDefaultName() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "/Users/m/.ssh/id_ed25519"]),
                       .importKey(path: "/Users/m/.ssh/id_ed25519", name: nil))
    }

    func testParsesImportKeyWithExplicitName() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--name", "work"]),
                       .importKey(path: "k.pem", name: "work"))
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
    }

    func testEncryptedPEMDetection() {
        XCTAssertTrue(KeyCLI.isEncryptedPEM("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC\n-----END RSA PRIVATE KEY-----"))
        XCTAssertFalse(KeyCLI.isEncryptedPEM("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----"))
        // openssh-key-v1 with bcrypt KDF (encrypted): the decoded payload
        // contains "bcrypt". "b3BlbnNzaC1rZXktdjEAAAAABmJjcnlwdA==" decodes to
        // "openssh-key-v1\0...bcrypt".
        XCTAssertTrue(KeyCLI.isEncryptedPEM("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABmJjcnlwdA==\n-----END OPENSSH PRIVATE KEY-----"))
        // openssh-key-v1 with "none" cipher (unencrypted):
        // "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU=" decodes to "openssh-key-v1\0...none".
        XCTAssertFalse(KeyCLI.isEncryptedPEM("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----"))
    }
}
