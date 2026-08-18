// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Whether a `CF_Authorization` cookie captured during Cloudflare Access
/// browser SSO (see `AccessLoginView` in the app target) belongs to
/// `hostname`.
///
/// Cookie domains may be exact (`"ssh.example.com"`) or parent-scoped
/// (`".example.com"`); comparison is case-insensitive because DNS names are,
/// while `WKHTTPCookieStore` normalizes cookie domains to lowercase and a
/// host's `hostname` field preserves whatever case the user typed or an
/// imported SSH config used.
///
/// Accepted boundary: a parent-scoped cookie (`Domain=.example.com`) is
/// accepted for any subdomain of `example.com`, so a token minted for a
/// different Access application under the same parent domain could in
/// principle be stored as this host's. That doesn't widen the browser's own
/// trust boundary — the cookie was already scoped that broadly by the
/// server that set it — and Cloudflare's edge rejects the token at connect
/// time if its `aud` claim doesn't match this application, so a
/// wrongly-captured token simply fails to dial rather than granting access.
public func accessCookieDomainMatches(cookieDomain: String, hostname: String) -> Bool {
    let cookie = cookieDomain.lowercased()
    let host = hostname.lowercased()
    let domain = cookie.hasPrefix(".") ? String(cookie.dropFirst()) : cookie
    return host == domain || host.hasSuffix("." + domain)
}
