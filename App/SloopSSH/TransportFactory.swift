// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit

/// Chooses a concrete `Transport` for a host. When the libssh2 xcframework is
/// linked (`CSSH` importable) it builds a real SSH connection over a `Dialer`
/// matching the host's connection method; otherwise it returns a
/// `MessageTransport` explaining what's missing, so the app stays usable
/// during the libssh2 bring-up.
public enum TransportFactory {
    public static func ssh(host: SSHHost,
                    credential: Credential,
                    knownHosts: KnownHostsStore,
                    hostKeyVerifier: HostKeyVerifier,
                    accessTokens: AccessTokenStore) -> Transport {
        #if canImport(CSSH)
        switch dialer(for: host, accessTokens: accessTokens) {
        case .ready(let dialer):
            return LibSSH2Transport(host: host, credential: credential,
                                    dialer: dialer,
                                    knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
        case .unavailable(let explanation):
            return MessageTransport(message: explanation)
        }
        #else
        return MessageTransport(message:
            "SSH isn't built into this app yet.\r\n" +
            "Add Vendor/libssh2.xcframework and rebuild — see Docs/SSH.md.\r\n")
        #endif
    }

    #if canImport(CSSH)
    /// A dialer for the host's connection method, or the reason there isn't
    /// one — as the text the terminal will show.
    ///
    /// Carrying the reason out of the one switch that discovered it is the
    /// point. When this returned a bare `Dialer?`, a second function had to
    /// re-derive *which* nil it was by re-calling `accessURL` and re-switching
    /// over the connection method — two switches to keep in step, one of whose
    /// branches ("a direct host with no dialer") could not happen at all.
    private enum DialerResolution {
        case ready(Dialer)
        case unavailable(String)
    }

    private static func dialer(for host: SSHHost,
                               accessTokens: AccessTokenStore) -> DialerResolution {
        switch host.connectionMethod {
        case .direct:
            return .ready(TCPDialer(host: host.hostname, port: host.port))

        case .cloudflareAccess:
            // "The hostname is wrong" must never read as "you need to sign
            // in": no login can fix a hostname, and telling the user to try
            // one traps them in a loop. The host list's pre-connect gate
            // catches the missing-token case before this is reached; nothing
            // gates the malformed-hostname one.
            guard let url = accessURL(for: host) else {
                let problem = host.hostname.isEmpty
                    ? "This host has no hostname."
                    : "\"\(host.hostname)\" isn't a valid hostname for Cloudflare Access."
                return .unavailable(problem + "\r\n" +
                    "Fix it in the host list, then reconnect — signing in won't help.\r\n")
            }
            let stored: AccessToken?
            do {
                stored = try accessTokens.validToken(for: host.hostname)
            } catch {
                // A keychain that refuses the read is not a missing login, and
                // must not be reported as one — no number of browser sign-ins
                // can write a token into a store that won't accept it.
                return .unavailable(
                    "Couldn't read the stored Cloudflare Access token for " +
                    "\(host.hostname): \(error.localizedDescription)\r\n" +
                    "Signing in again won't help until that's fixed.\r\n")
            }
            guard let token = stored else {
                return .unavailable(
                    "Cloudflare Access needs a browser login for \(host.hostname).\r\n" +
                    "Go back to the host list and reconnect to sign in.\r\n")
            }
            let dialer = CloudflareAccessDialer(url: url, hostname: host.hostname,
                                                token: token.raw)
            return .ready(TokenClearingDialer(wrapping: dialer, hostname: host.hostname,
                                              accessTokens: accessTokens))

        case .tailscale:
            #if SLOOP_TAILSCALE
            // Sloop's own tsnet node — no Tailscale app, no system VPN slot.
            // Bringing it up happens inside the dial, so the first connect is
            // where an unauthorized device is told to authorize itself.
            return .ready(TailscaleDialer(host: host.hostname, port: host.port))
            #else
            // This build doesn't link libtailscale, so the only way a tailnet
            // host is reachable is the Tailscale app's system VPN — and when
            // that is up, the OS routes 100.64.0.0/10 and MagicDNS for every
            // app, so an ordinary dial works and this method does nothing that
            // Direct wouldn't. When it isn't up, saying so is the whole value:
            // the alternative is a name that doesn't resolve or a connect that
            // times out, neither of which mentions Tailscale.
            guard TailnetPresence.isConnected else {
                return .unavailable(
                    "This build of Sloop can't join a tailnet on its own, and this " +
                    "device isn't on one, so \(host.hostname) can't be reached.\r\n" +
                    "Install the Tailscale app and connect it, then set this host to " +
                    "Direct with its MagicDNS name.\r\n")
            }
            return .ready(TCPDialer(host: host.hostname, port: host.port))
            #endif
        }
    }

    /// The `wss://` URL a Cloudflare Access dialer would connect to, or nil
    /// when `host.hostname` doesn't form one: empty, or containing characters
    /// `URL` won't accept unencoded (a stray space, say).
    ///
    /// The host component is checked, not just the parse. `URL(string:)`
    /// happily returns a non-nil `wss://` for an empty hostname — a URL with
    /// no host at all — which used to be handed to the dialer, where it spent
    /// the full 20 s dial timeout failing to connect to nothing. The user has
    /// a hostname field they left blank; they should be told that, now.
    private static func accessURL(for host: SSHHost) -> URL? {
        guard let url = URL(string: "wss://\(host.hostname)"),
              url.host()?.isEmpty == false else { return nil }
        return url
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
public final class TokenClearingDialer: Dialer {
    private let wrapped: Dialer
    private let hostname: String
    private let accessTokens: AccessTokenStore

    public init(wrapping wrapped: Dialer, hostname: String, accessTokens: AccessTokenStore) {
        self.wrapped = wrapped
        self.hostname = hostname
        self.accessTokens = accessTokens
    }

    public func dial() throws -> Int32 {
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
