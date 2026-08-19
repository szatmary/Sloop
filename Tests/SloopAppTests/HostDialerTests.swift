// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
import SloopKit
@testable import SloopSSH

/// How a host is reached, decided once.
///
/// There were two of these switches: one in `TransportFactory` for the
/// terminal, one in `SFTPClientFactory` for the File Provider. They had already
/// started to drift — the hostname check was copied, the tailnet role was
/// hard-coded on one side and a parameter on the other — and the codebase had
/// been through this exact failure before, when the Mosh probe made its own
/// dialer and every Mosh session over the tailnet quietly became an SSH one.
final class HostDialerTests: XCTestCase {
    private func host(_ method: ConnectionMethod, hostname: String = "example.com") -> SSHHost {
        SSHHost(alias: "t", hostname: hostname, username: "u", connectionMethod: method)
    }

    private func resolve(_ host: SSHHost,
                         tokens: AccessTokenStore = InMemoryAccessTokenStore(),
                         whenTailnetUnavailable fallback: TailnetFallback = .refuse) throws -> Dialer {
        try HostDialer.resolve(for: host, accessTokens: tokens, role: .app,
                               presenter: NoAuthorizationPresenter(),
                               whenTailnetUnavailable: fallback)
    }

    func testADirectHostDialsItsHostnameStraight() throws {
        XCTAssertTrue(try resolve(host(.direct)) is TCPDialer)
    }

    /// The host list's pre-connect gate is built on this being the answer for a
    /// host with no stored token — it is what opens the login sheet.
    func testAnAccessHostWithNoStoredTokenNeedsABrowserLogin() {
        XCTAssertThrowsError(try resolve(host(.cloudflareAccess))) { error in
            XCTAssertEqual(error as? DialerUnavailable, .accessLoginRequired("example.com"))
        }
    }

    /// No login can fix a hostname, and telling the user to try one traps them
    /// in a loop.
    func testAMalformedAccessHostnameIsAHostnameProblemNotALoginOne() {
        XCTAssertThrowsError(try resolve(host(.cloudflareAccess, hostname: "exa mple.com"))) { error in
            XCTAssertEqual(error as? DialerUnavailable, .malformedHostname("exa mple.com"))
        }
    }

    /// `URL(string: "wss://")` parses perfectly well as a URL with no host at
    /// all. That used to be dialed, and the user waited out the full 20 s
    /// connect timeout to be told nothing useful.
    func testAnEmptyAccessHostnameIsAHostnameProblem() {
        XCTAssertThrowsError(try resolve(host(.cloudflareAccess, hostname: ""))) { error in
            XCTAssertEqual(error as? DialerUnavailable, .malformedHostname(""))
        }
    }

    /// A keychain that refuses the read is not a hostname nobody has signed in
    /// to. No number of browser logins writes a token into a store that won't
    /// take one.
    func testAStoreThatCannotBeReadIsNotReportedAsAMissingLogin() {
        let store = UnreadableAccessTokenStore()
        XCTAssertThrowsError(try resolve(host(.cloudflareAccess), tokens: store)) { error in
            guard case .accessTokenUnreadable(let hostname, _)? = error as? DialerUnavailable else {
                return XCTFail("expected accessTokenUnreadable, got \(error)")
            }
            XCTAssertEqual(hostname, "example.com")
        }
    }

    #if !SLOOP_TAILSCALE
    /// The two callers differ on exactly one thing, and it is a policy, not a
    /// second switch: the terminal may ride the Tailscale app's system VPN when
    /// it happens to be up, because the user is right there watching. The File
    /// Provider may not — it runs in the background at the system's discretion,
    /// so a route that exists now is not a property a saved domain can rely on.
    func testTheFileProviderRefusesATailnetHostThisBuildCannotReach() {
        XCTAssertThrowsError(try resolve(host(.tailscale, hostname: "box.tail.ts.net"),
                                         whenTailnetUnavailable: .refuse)) { error in
            XCTAssertEqual(error as? DialerUnavailable, .tailnetUnreachable("box.tail.ts.net"))
        }
    }
    #endif
}

/// Every reason a host cannot be dialed has to reach two audiences: someone
/// looking at a terminal inside Sloop, and someone looking at a folder in
/// Files.app that will not open. They are told different things on purpose —
/// "go back to the host list" means nothing to the second — and the reason
/// being one value is what stops the two from disagreeing about *what* is
/// wrong while they differ about how to say it.
extension HostDialerTests {
    private var everyReason: [DialerUnavailable] {
        [.malformedHostname("example.com"),
         .accessLoginRequired("example.com"),
         .accessTokenUnreadable(hostname: "example.com", underlying: "keychain locked"),
         .tailnetUnreachable("example.com")]
    }

    func testEveryReasonNamesTheHostInBothRenderings() {
        for reason in everyReason {
            XCTAssertTrue(reason.errorDescription?.contains("example.com") == true,
                          "Files.app text should name the host: \(reason)")
            XCTAssertTrue(reason.terminalText.contains("example.com"),
                          "terminal text should name the host: \(reason)")
        }
    }

    /// The terminal is a terminal: a bare `\n` leaves the next line indented to
    /// wherever the last one ended.
    func testTheTerminalRenderingEndsItsLinesForATerminal() {
        for reason in everyReason {
            XCTAssertTrue(reason.terminalText.hasSuffix("\r\n"), "\(reason)")
            XCTAssertFalse(reason.terminalText.contains("\n\n"),
                           "a bare newline means a stair-stepped line: \(reason)")
        }
    }

    /// Only one of these is a login problem. The other three each said so the
    /// hard way at some point — by sending someone to a browser to fix a typo,
    /// a locked keychain, or a missing tailnet.
    func testOnlyTheMissingLoginAsksForALogin() {
        for reason in everyReason {
            let mentionsLogin = reason.terminalText.lowercased().contains("login")
                || reason.terminalText.lowercased().contains("sign in")
            XCTAssertEqual(mentionsLogin, reason == .accessLoginRequired("example.com"),
                           "\(reason) should\(mentionsLogin ? " not" : "") mention signing in")
        }
    }
}

/// A store whose reads fail — a locked or otherwise unreadable keychain.
private final class UnreadableAccessTokenStore: AccessTokenStore, @unchecked Sendable {
    struct Locked: Error {}
    func rawToken(for hostname: String) throws -> String? { throw Locked() }
    func setRawToken(_ raw: String, for hostname: String) throws { throw Locked() }
    func removeToken(for hostname: String) throws { throw Locked() }
}
