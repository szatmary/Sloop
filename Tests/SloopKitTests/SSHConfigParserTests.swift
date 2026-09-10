// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class SSHConfigParserTests: XCTestCase {

    func testParsesBasicBlock() {
        let config = """
        Host web
            HostName example.com
            User deploy
            Port 2222
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].alias, "web")
        XCTAssertEqual(hosts[0].hostname, "example.com")
        XCTAssertEqual(hosts[0].username, "deploy")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].auth, .password)
    }

    func testMultipleBlocksInOrder() {
        let config = """
        Host a
            HostName a.example.com
            User alice

        Host b
            HostName b.example.com
            User bob
            Port 22
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["a", "b"])
        XCTAssertEqual(hosts[0].username, "alice")
        XCTAssertEqual(hosts[0].port, 22)          // default when omitted
        XCTAssertEqual(hosts[1].hostname, "b.example.com")
    }

    func testHostnameDefaultsToAlias() {
        let hosts = SSHConfigParser.parse("Host bare\n    User me")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "bare")   // no HostName → use the alias
        XCTAssertEqual(hosts[0].username, "me")
    }

    func testWildcardBlocksSkipped() {
        let config = """
        Host *
            User default

        Host prod?
            HostName prod.example.com

        Host real
            HostName real.example.com
            User carol
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["real"])
    }

    func testCommentsAndBlankLinesIgnored() {
        let config = """
        # a comment
        Host x

            # indented comment
            HostName x.example.com

        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "x.example.com")
    }

    func testEqualsSeparatorAndCaseInsensitiveKeywords() {
        let config = """
        HOST y
            hostname=y.example.com
            USER = yuki
            Port=2020
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "y.example.com")
        XCTAssertEqual(hosts[0].username, "yuki")
        XCTAssertEqual(hosts[0].port, 2020)
    }

    func testMultiPatternHostUsesFirstToken() {
        let hosts = SSHConfigParser.parse("Host web1 web2 web3\n    HostName cluster.example.com")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].alias, "web1")
        XCTAssertEqual(hosts[0].hostname, "cluster.example.com")
    }

    func testEmptyInputYieldsNoHosts() {
        XCTAssertTrue(SSHConfigParser.parse("").isEmpty)
        XCTAssertTrue(SSHConfigParser.parse("# only a comment\n\n").isEmpty)
    }

    func testInvalidPortIgnoredFallsBackToDefault() {
        let hosts = SSHConfigParser.parse("Host z\n    HostName z.example.com\n    Port notanumber")
        XCTAssertEqual(hosts[0].port, 22)
    }

    // MARK: format

    func testFormatEmitsOnlyNonDefaultFields() {
        let host = SSHHost(alias: "web", hostname: "example.com", port: 2222, username: "deploy")
        let text = SSHConfigParser.format([host])
        XCTAssertTrue(text.contains("Host web"))
        XCTAssertTrue(text.contains("HostName example.com"))
        XCTAssertTrue(text.contains("User deploy"))
        XCTAssertTrue(text.contains("Port 2222"))
    }

    func testFormatOmitsHostNameEqualToAliasAndDefaultPort() {
        let host = SSHHost(alias: "bare", hostname: "bare", port: 22, username: "")
        let text = SSHConfigParser.format([host])
        XCTAssertTrue(text.contains("Host bare"))
        XCTAssertFalse(text.contains("HostName"))   // equals alias → omitted
        XCTAssertFalse(text.contains("Port"))       // default → omitted
        XCTAssertFalse(text.contains("User"))       // empty → omitted
    }

    // MARK: connection method

    /// The one that matters: a tunneled host must not come back as `.direct`.
    /// It used to — `format`/`parse` carried no connection method at all — and
    /// `TransportFactory` would then hand the re-imported host a `TCPDialer`
    /// aimed at the Access application's public hostname, sending its username
    /// and secret to whatever answers there on port 22.
    func testConnectionMethodSurvivesFormatAndParse() {
        let originals = [
            SSHHost(alias: "tunnel", hostname: "ssh.example.com", username: "matt",
                    connectionMethod: .cloudflareAccess),
            SSHHost(alias: "tailnet", hostname: "box.tail1234.ts.net", username: "matt",
                    connectionMethod: .tailscale),
            SSHHost(alias: "plain", hostname: "plain.example.com", username: "matt"),
        ]
        let reparsed = SSHConfigParser.parse(SSHConfigParser.format(originals))
        XCTAssertEqual(reparsed.map(\.alias), ["tunnel", "tailnet", "plain"])
        XCTAssertEqual(reparsed.map(\.connectionMethod),
                       [.cloudflareAccess, .tailscale, .direct])
    }

    /// The directive rides in a comment so the export is still something
    /// `ssh -F` will read: an unknown *keyword* is a hard error in OpenSSH.
    func testConnectionMethodIsEmittedAsAComment() {
        let text = SSHConfigParser.format([
            SSHHost(alias: "tunnel", hostname: "ssh.example.com", username: "matt",
                    connectionMethod: .cloudflareAccess)])
        XCTAssertTrue(text.contains("# SloopConnectionMethod cloudflareAccess"), text)
    }

    /// `.direct` is the default, so it stays out of the file — same rule as
    /// `Port 22` and an empty `User`.
    func testDirectMethodEmitsNoDirective() {
        let text = SSHConfigParser.format([
            SSHHost(alias: "plain", hostname: "plain.example.com", username: "matt")])
        XCTAssertFalse(text.contains("SloopConnectionMethod"), text)
    }

    /// A method this build doesn't understand — a config written by a newer
    /// Sloop — must drop the host, not import it as a direct connection. The
    /// host is recoverable (re-add it, or import with a build that knows the
    /// method); a credential sent to the wrong server is not.
    func testUnknownConnectionMethodDropsTheHostInsteadOfDowngradingIt() {
        let config = """
        Host future
            HostName future.example.com
            User matt
            # SloopConnectionMethod wireguard

        Host plain
            HostName plain.example.com
            User matt
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["plain"])
    }

    /// The directive is scoped to its own block: an unknown method in one
    /// block must not leak into, or discard, the next.
    func testUnknownConnectionMethodDoesNotAffectLaterBlocks() {
        let config = """
        Host future
            # SloopConnectionMethod wireguard

        Host tunnel
            HostName ssh.example.com
            # SloopConnectionMethod cloudflareAccess

        Host plain
            HostName plain.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["tunnel", "plain"])
        XCTAssertEqual(hosts.map(\.connectionMethod), [.cloudflareAccess, .direct])
    }

    /// Ordinary comments — including ones that merely mention the app — are
    /// still comments.
    func testUnrelatedCommentsAreStillIgnored() {
        let config = """
        # Sloop wrote this file
        Host plain
            HostName plain.example.com
            # SloopConnectionMethod
            #
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["plain"])
        XCTAssertEqual(hosts[0].connectionMethod, .direct)
    }

    /// Same spelling tolerance as every other keyword here: case-insensitive,
    /// `=` or whitespace separated, with or without a space after the `#`.
    func testConnectionMethodDirectiveSpellingIsTolerant() {
        let config = """
        Host a
            #sloopconnectionmethod=cloudflareAccess
        """
        XCTAssertEqual(SSHConfigParser.parse(config).first?.connectionMethod, .cloudflareAccess)
    }

    func testRoundTripThroughFormatAndParse() {
        let originals = [
            SSHHost(alias: "a", hostname: "a.example.com", port: 22, username: "alice"),
            SSHHost(alias: "b", hostname: "b.example.com", port: 2020, username: "bob"),
            SSHHost(alias: "c", hostname: "c", port: 22, username: ""),   // hostname == alias
        ]
        let reparsed = SSHConfigParser.parse(SSHConfigParser.format(originals))
        XCTAssertEqual(reparsed.count, 3)
        for (original, round) in zip(originals, reparsed) {
            XCTAssertEqual(round.alias, original.alias)
            XCTAssertEqual(round.hostname, original.hostname)
            XCTAssertEqual(round.username, original.username)
            XCTAssertEqual(round.port, original.port)
        }
    }
}
