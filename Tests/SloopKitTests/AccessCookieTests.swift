// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

/// Table tests for the predicate `AccessLoginView`'s cookie-capture
/// coordinator uses to decide whether a `CF_Authorization` cookie belongs to
/// the host being signed into. This is the one security-critical piece of
/// the browser SSO flow (Task 10), so it's pulled out as a free function and
/// tested directly rather than only reachable through UI code.
final class AccessCookieTests: XCTestCase {
    func testExactDomainMatches() {
        XCTAssertTrue(accessCookieDomainMatches(cookieDomain: "ssh.example.com",
                                                hostname: "ssh.example.com"))
    }

    func testParentScopedDomainMatches() {
        XCTAssertTrue(accessCookieDomainMatches(cookieDomain: ".example.com",
                                                hostname: "ssh.example.com"))
    }

    func testAttackerSuffixDomainIsRejected() {
        // "notexample.com" ends in "example.com" as a raw substring, but is
        // not a subdomain of it — the dot-anchored suffix check must reject
        // this, not just a naive hasSuffix("example.com").
        XCTAssertFalse(accessCookieDomainMatches(cookieDomain: "example.com",
                                                 hostname: "notexample.com"))
        XCTAssertFalse(accessCookieDomainMatches(cookieDomain: ".example.com",
                                                 hostname: "notexample.com"))
        XCTAssertFalse(accessCookieDomainMatches(cookieDomain: "example.com",
                                                 hostname: "evilexample.com"))
    }

    func testUnrelatedDomainIsRejected() {
        // e.g. a cookie set for the IdP's own domain during the redirect
        // chain must never be mistaken for the target host's token.
        XCTAssertFalse(accessCookieDomainMatches(cookieDomain: "idp.example.org",
                                                 hostname: "ssh.example.com"))
    }

    func testMoreSpecificSubdomainCookieDoesNotMatchDifferentSubdomain() {
        XCTAssertFalse(accessCookieDomainMatches(cookieDomain: "other.ssh.example.com",
                                                 hostname: "ssh.example.com"))
    }

    func testParentDomainCookieMatchesDeeperSubdomain() {
        // A parent-scoped cookie legitimately covers a more specific host.
        XCTAssertTrue(accessCookieDomainMatches(cookieDomain: ".example.com",
                                                hostname: "deep.ssh.example.com"))
    }

    func testMixedCaseHostnameMatches() {
        // WKHTTPCookieStore normalizes cookie domains to lowercase, but a
        // host's `hostname` field preserves whatever case the user typed or
        // an imported SSH config used.
        XCTAssertTrue(accessCookieDomainMatches(cookieDomain: "ssh.example.com",
                                                hostname: "SSH.Example.com"))
    }

    func testMixedCaseCookieDomainMatches() {
        XCTAssertTrue(accessCookieDomainMatches(cookieDomain: "SSH.EXAMPLE.COM",
                                                hostname: "ssh.example.com"))
    }

    func testMixedCaseOnBothSidesMatches() {
        XCTAssertTrue(accessCookieDomainMatches(cookieDomain: ".Example.COM",
                                                hostname: "Ssh.example.COM"))
    }
}
