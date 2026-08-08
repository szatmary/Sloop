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
