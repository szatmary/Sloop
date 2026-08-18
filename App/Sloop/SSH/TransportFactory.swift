// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit

/// Chooses a concrete `Transport` for a host. When the libssh2 xcframework is
/// linked (`CSSH` importable) it builds a real SSH connection over a `Dialer`
/// matching the host's connection method; otherwise it returns a
/// `MessageTransport` explaining what's missing, so the app stays usable
/// during the libssh2 bring-up.
enum TransportFactory {
    static func ssh(host: SSHHost,
                    credential: Credential,
                    knownHosts: KnownHostsStore,
                    hostKeyVerifier: HostKeyVerifier,
                    accessTokens: AccessTokenStore) -> Transport {
        #if canImport(CSSH)
        guard let dialer = dialer(for: host, accessTokens: accessTokens) else {
            return unavailable(for: host)
        }
        return LibSSH2Transport(host: host, credential: credential,
                                dialer: dialer,
                                knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
        #else
        return MessageTransport(message:
            "SSH isn't built into this app yet.\r\n" +
            "Add Vendor/libssh2.xcframework and rebuild — see Docs/SSH.md.\r\n")
        #endif
    }

    #if canImport(CSSH)
    /// The dialer for the host's connection method, or nil when the method
    /// can't produce one right now (a malformed hostname, no Access token,
    /// unbuilt integration). `unavailable(for:)` re-derives which of those it
    /// was, so the two failure causes reach the user as different messages.
    private static func dialer(for host: SSHHost,
                               accessTokens: AccessTokenStore) -> Dialer? {
        switch host.connectionMethod {
        case .direct:
            return TCPDialer(host: host.hostname, port: host.port)
        case .cloudflareAccess:
            guard let url = accessURL(for: host),
                  let token = accessTokens.validToken(for: host.hostname) else {
                return nil
            }
            let dialer = CloudflareAccessDialer(url: url, hostname: host.hostname,
                                                token: token.raw)
            return TokenClearingDialer(wrapping: dialer, hostname: host.hostname,
                                       accessTokens: accessTokens)
        case .tailscale:
            return nil
        }
    }

    /// The `wss://` URL a Cloudflare Access dialer would connect to, or nil
    /// when `host.hostname` doesn't form a valid URL (empty, or containing
    /// characters `URL` won't accept unencoded, e.g. a stray space).
    private static func accessURL(for host: SSHHost) -> URL? {
        URL(string: "wss://\(host.hostname)")
    }

    /// Why `dialer(for:)` returned nil, as terminal text. For Cloudflare
    /// Access this must not conflate "hostname is malformed" — a
    /// configuration error no login can fix — with "no valid token" — the
    /// case the host list's pre-connect gate normally catches before this is
    /// ever reached, but the malformed-hostname case isn't gated anywhere.
    private static func unavailable(for host: SSHHost) -> Transport {
        switch host.connectionMethod {
        case .cloudflareAccess where accessURL(for: host) == nil:
            return MessageTransport(message:
                "\"\(host.hostname)\" isn't a valid hostname for Cloudflare Access.\r\n" +
                "Fix it in the host list, then reconnect — signing in won't help.\r\n")
        case .cloudflareAccess:
            return MessageTransport(message:
                "Cloudflare Access needs a browser login for \(host.hostname).\r\n" +
                "Go back to the host list and reconnect to sign in.\r\n")
        case .tailscale:
            return MessageTransport(message:
                "Tailscale support isn't built into this app yet — see Docs/ROADMAP.md.\r\n")
        case .direct:
            return MessageTransport(message:
                "Unable to connect to \(host.hostname).\r\n")
        }
    }
    #endif
}

#if canImport(CSSH)
/// Wraps a Cloudflare Access dialer so a token the edge itself rejects can't
/// strand the host.
///
/// A locally-unexpired token can still be rejected server-side — the Access
/// session was revoked, a device-posture rule was added, the cookie was
/// parent-domain-scoped and belongs to a different Access app — and
/// `dial()` surfaces that as `SSHError.accessLoginRequired`/`.accessDenied`.
/// Without this, `HostListModel.needsAccessLogin` keeps finding the same
/// locally-valid-but-server-rejected token on every retry, so the login
/// sheet this exact error message promises never opens; the user is stuck
/// until the JWT's own `exp` passes. Clearing the stored token on that
/// specific failure makes the next `needsAccessLogin` check see nothing,
/// which is what actually opens the sheet.
///
/// Deliberately narrow: it removes the token only for the two errors that
/// mean "the edge rejected this token," never for a network hiccup that
/// deserves a plain retry with the same token.
///
/// Internal rather than file-private so `SloopAppTests` can drive it
/// directly against a fake `Dialer`/`AccessTokenStore` — this exact
/// catch-and-clear behavior is the whole fix for the stranded-host bug, and
/// exercising it only through a real WebSocket handshake to `wss://<host>`
/// wouldn't be practical from a unit test.
final class TokenClearingDialer: Dialer {
    private let wrapped: Dialer
    private let hostname: String
    private let accessTokens: AccessTokenStore

    init(wrapping wrapped: Dialer, hostname: String, accessTokens: AccessTokenStore) {
        self.wrapped = wrapped
        self.hostname = hostname
        self.accessTokens = accessTokens
    }

    func dial() throws -> Int32 {
        do {
            return try wrapped.dial()
        } catch {
            switch error as? SSHError {
            case .accessLoginRequired, .accessDenied:
                // Best-effort: a keychain failure here must not mask the dial
                // error that's about to be rethrown below.
                try? accessTokens.removeToken(for: hostname)
            default:
                break
            }
            throw error
        }
    }
}
#endif
