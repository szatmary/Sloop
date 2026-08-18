// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class SSHURLTests: XCTestCase {

    func testHostOnly() {
        let url = SSHURL(string: "ssh://example.com")
        XCTAssertEqual(url?.hostname, "example.com")
        XCTAssertNil(url?.username)
        XCTAssertNil(url?.port)
    }

    func testUserAndHost() {
        let url = SSHURL(string: "ssh://matt@example.com")
        XCTAssertEqual(url?.username, "matt")
        XCTAssertEqual(url?.hostname, "example.com")
    }

    func testExplicitPort() {
        let url = SSHURL(string: "ssh://matt@example.com:2222")
        XCTAssertEqual(url?.hostname, "example.com")
        XCTAssertEqual(url?.port, 2222)
    }

    /// A trailing slash is common in shared links and means nothing here.
    func testTrailingSlashIsIgnored() {
        let url = SSHURL(string: "ssh://matt@example.com/")
        XCTAssertEqual(url?.hostname, "example.com")
        XCTAssertEqual(url?.username, "matt")
    }

    func testIPv4Literal() {
        let url = SSHURL(string: "ssh://root@192.0.2.10:22")
        XCTAssertEqual(url?.hostname, "192.0.2.10")
        XCTAssertEqual(url?.port, 22)
    }

    /// RFC 3986 brackets an IPv6 literal so the colons aren't read as a port.
    /// The brackets are syntax, not part of the address — libssh2 wants the
    /// bare address.
    func testIPv6LiteralLosesItsBrackets() {
        let url = SSHURL(string: "ssh://[2001:db8::1]:2222")
        XCTAssertEqual(url?.hostname, "2001:db8::1")
        XCTAssertEqual(url?.port, 2222)
    }

    func testPercentEscapedUsernameIsDecoded() {
        let url = SSHURL(string: "ssh://first%20last@example.com")
        XCTAssertEqual(url?.username, "first last")
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(SSHURL(string: "SSH://example.com")?.hostname, "example.com")
    }

    // MARK: Rejection

    func testRejectsANonSSHScheme() {
        XCTAssertNil(SSHURL(string: "https://example.com"))
        XCTAssertNil(SSHURL(string: "telnet://example.com"))
    }

    func testRejectsAMissingHost() {
        XCTAssertNil(SSHURL(string: "ssh://"))
        XCTAssertNil(SSHURL(string: "ssh://matt@"))
    }

    func testRejectsGarbage() {
        XCTAssertNil(SSHURL(string: ""))
        XCTAssertNil(SSHURL(string: "not a url at all"))
    }

    /// A port outside 1...65535 is not a port. Accepting it would hand
    /// libssh2 a value it cannot use, failing later and less clearly.
    func testRejectsAnOutOfRangePort() {
        XCTAssertNil(SSHURL(string: "ssh://example.com:0"))
        XCTAssertNil(SSHURL(string: "ssh://example.com:70000"))
    }

    // MARK: Turning one into a host

    func testMakesAHostUsingTheHostnameAsTheAlias() {
        let host = SSHURL(string: "ssh://matt@example.com:2222")!.makeHost()
        XCTAssertEqual(host.alias, "example.com")
        XCTAssertEqual(host.hostname, "example.com")
        XCTAssertEqual(host.username, "matt")
        XCTAssertEqual(host.port, 2222)
    }

    /// SSH's own default, so a link without one behaves like `ssh host`.
    func testAMissingPortDefaultsTo22() {
        XCTAssertEqual(SSHURL(string: "ssh://example.com")!.makeHost().port, 22)
    }

    /// A link that names no user cannot invent one; the host editor asks.
    func testAMissingUsernameMakesAnEmptyUsername() {
        XCTAssertEqual(SSHURL(string: "ssh://example.com")!.makeHost().username, "")
    }

    // MARK: Matching a saved host

    func testMatchesASavedHostOnHostnameAndUser() {
        let saved = SSHHost(alias: "prod", hostname: "example.com",
                            port: 22, username: "matt")
        let url = SSHURL(string: "ssh://matt@example.com")!
        XCTAssertTrue(url.matches(saved))
    }

    func testDoesNotMatchADifferentUser() {
        let saved = SSHHost(alias: "prod", hostname: "example.com",
                            port: 22, username: "matt")
        XCTAssertFalse(SSHURL(string: "ssh://root@example.com")!.matches(saved))
    }

    func testDoesNotMatchADifferentPort() {
        let saved = SSHHost(alias: "prod", hostname: "example.com",
                            port: 22, username: "matt")
        XCTAssertFalse(SSHURL(string: "ssh://matt@example.com:2222")!.matches(saved))
    }

    /// A link with no user is a link about a machine, not an account — it
    /// should find the host you already saved for it.
    func testAUserlessLinkMatchesOnHostnameAlone() {
        let saved = SSHHost(alias: "prod", hostname: "example.com",
                            port: 22, username: "matt")
        XCTAssertTrue(SSHURL(string: "ssh://example.com")!.matches(saved))
    }

    func testHostnameMatchingIsCaseInsensitive() {
        let saved = SSHHost(alias: "prod", hostname: "Example.COM",
                            port: 22, username: "matt")
        XCTAssertTrue(SSHURL(string: "ssh://matt@example.com")!.matches(saved))
    }
}
