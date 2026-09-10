// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit

/// Why a host cannot be dialed.
///
/// A type rather than a message, because the same reason has to reach two
/// audiences: someone looking at a terminal inside Sloop, and someone looking
/// at a folder in Files.app that will not open. They need to be told different
/// things — "go back to the host list" means nothing to the second — and when
/// each side decided the reason *and* its wording for itself, the two decisions
/// drifted apart. Now there is one reason and two renderings of it, side by
/// side below, so a new case cannot be added without answering for both.
public enum DialerUnavailable: Error, LocalizedError, UserActionRequiredError, Equatable {
    /// The hostname doesn't form a `wss://` URL: empty, or carrying characters
    /// `URL` won't take unencoded.
    case malformedHostname(String)
    /// Cloudflare Access has no usable token for this hostname.
    case accessLoginRequired(String)
    /// The token store itself couldn't be read.
    case accessTokenUnreadable(hostname: String, underlying: String)
    /// A tailnet host, in a build that can't join a tailnet on its own.
    case tailnetUnreachable(String)

    /// For a reader who is *outside* the app — the File Provider's only user
    /// interface is the error text Files.app puts on a folder, so every case
    /// here names the one action that fixes it, and that action is "open
    /// Sloop".
    public var errorDescription: String? {
        switch self {
        case .malformedHostname(let hostname):
            return hostname.isEmpty
                ? "This host has no hostname. Fix it in Sloop."
                : "\"\(hostname)\" isn't a valid hostname for Cloudflare Access. Fix it in Sloop."
        case .accessLoginRequired(let hostname):
            return "Open Sloop and sign in to Cloudflare Access for \(hostname)."
        case .accessTokenUnreadable(let hostname, let underlying):
            return "Sloop couldn't read the stored Cloudflare Access token for "
                + "\(hostname): \(underlying). Signing in again won't help until that's fixed."
        case .tailnetUnreachable(let hostname):
            return "This build of Sloop can't join a tailnet on its own, so \(hostname) "
                + "can't be reached from Files."
        }
    }

    /// For a reader who is already looking at the terminal that just failed to
    /// connect. `\r\n` because that is a terminal: a bare `\n` leaves the next
    /// line indented to wherever the last one ended.
    public var terminalText: String {
        switch self {
        case .malformedHostname(let hostname):
            // "The hostname is wrong" must never read as "you need to sign in":
            // no login can fix a hostname, and telling the user to try one traps
            // them in a loop.
            let problem = hostname.isEmpty
                ? "This host has no hostname."
                : "\"\(hostname)\" isn't a valid hostname for Cloudflare Access."
            return problem + "\r\nFix it in the host list, then reconnect — "
                + "signing in won't help.\r\n"
        case .accessLoginRequired(let hostname):
            return "Cloudflare Access needs a browser login for \(hostname).\r\n"
                + "Go back to the host list and reconnect to sign in.\r\n"
        case .accessTokenUnreadable(let hostname, let underlying):
            // A keychain that refuses the read is not a missing login, and must
            // not be reported as one — no number of browser sign-ins can write a
            // token into a store that won't accept it.
            return "Couldn't read the stored Cloudflare Access token for "
                + "\(hostname): \(underlying)\r\n"
                + "That isn't something reconnecting will fix.\r\n"
        case .tailnetUnreachable(let hostname):
            return "This build of Sloop can't join a tailnet on its own, and this device "
                + "isn't on one, so \(hostname) can't be reached.\r\n"
                + "Install the Tailscale app and connect it, then set this host to Direct "
                + "with its MagicDNS name.\r\n"
        }
    }
}

/// What to do about a tailnet host in a build that links no `libtailscale`.
///
/// The one thing the terminal and the File Provider genuinely disagree about —
/// a policy, deliberately a parameter rather than a second switch over
/// `ConnectionMethod`, because a second switch is how these two drifted apart
/// in the first place.
public enum TailnetFallback {
    /// Dial normally when the Tailscale app's system VPN is up: it routes
    /// 100.64.0.0/10 and MagicDNS for every app on the device, so an ordinary
    /// dial reaches the host and this method does nothing Direct wouldn't. Fine
    /// for the terminal, where the user is present and watching.
    case systemVPNIfPresent
    /// Refuse outright. The File Provider runs in the background at the
    /// system's discretion, so a route that happens to exist right now is not a
    /// property a saved domain can rely on.
    case refuse
}

/// The dialer a host is reached through — the single answer to "how does this
/// host's byte stream get established", for every caller that needs one.
///
/// Not gated on `canImport(CSSH)`, though every caller today feeds the result
/// to libssh2: nothing about *choosing* a dialer needs libssh2, and leaving the
/// decision buildable everywhere is what lets it be tested in the plain build
/// that CI actually runs.
public enum HostDialer {
    /// - Parameters:
    ///   - role: which tsnet identity to dial with. The app and the File
    ///     Provider extension are separate processes, and so separate devices
    ///     on the tailnet.
    ///   - presenter: where a device-authorization URL goes. A process with no
    ///     UI passes `NoAuthorizationPresenter`; the error thrown alongside is
    ///     what actually reaches its user.
    public static func resolve(for host: SSHHost,
                               accessTokens: AccessTokenStore,
                               role: SloopStorage.TailnetRole,
                               presenter: TailscaleAuthorizationPresenter,
                               whenTailnetUnavailable fallback: TailnetFallback) throws -> Dialer {
        switch host.connectionMethod {
        case .direct:
            return TCPDialer(host: host.hostname, port: host.port)

        case .cloudflareAccess:
            // The host component is checked, not just the parse.
            // `URL(string:)` happily returns a non-nil `wss://` for an empty
            // hostname — a URL with no host at all — which used to be handed to
            // the dialer, where it spent the full 20 s dial timeout failing to
            // connect to nothing.
            guard let url = URL(string: "wss://\(host.hostname)"),
                  url.host()?.isEmpty == false else {
                throw DialerUnavailable.malformedHostname(host.hostname)
            }
            let stored: AccessToken?
            do {
                stored = try accessTokens.validToken(for: host.hostname)
            } catch {
                throw DialerUnavailable.accessTokenUnreadable(
                    hostname: host.hostname, underlying: error.localizedDescription)
            }
            guard let token = stored else {
                throw DialerUnavailable.accessLoginRequired(host.hostname)
            }
            let dialer = CloudflareAccessDialer(url: url, hostname: host.hostname,
                                                token: token.raw)
            return TokenClearingDialer(wrapping: dialer, hostname: host.hostname,
                                       accessTokens: accessTokens)

        case .tailscale:
            #if SLOOP_TAILSCALE
            // Sloop's own tsnet node — no Tailscale app, no system VPN slot.
            // Bringing it up happens inside the dial, so the first connect is
            // where an unauthorized device is told to authorize itself.
            return TailscaleDialer(host: host.hostname, port: host.port,
                                   role: role, presenter: presenter)
            #else
            switch fallback {
            case .systemVPNIfPresent where TailnetPresence.isConnected:
                return TCPDialer(host: host.hostname, port: host.port)
            case .systemVPNIfPresent, .refuse:
                // Saying so is the whole value: the alternative is a name that
                // doesn't resolve or a connect that times out, neither of which
                // mentions Tailscale.
                throw DialerUnavailable.tailnetUnreachable(host.hostname)
            }
            #endif
        }
    }
}

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
