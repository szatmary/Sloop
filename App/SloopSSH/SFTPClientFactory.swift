// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit

/// Builds an `SFTPClient` for a host — the file-transfer counterpart to
/// `TransportFactory`, reusing the same `Dialer` seam so a tunneled host
/// reaches SFTP exactly the way it reaches a shell.
///
/// Everything it refuses, it refuses with a sentence a person can act on. This
/// runs inside the File Provider extension, where the only user interface is
/// the error text Files.app shows on a folder.
public enum SFTPClientFactory {
    /// Why a host has no SFTP client, phrased for someone looking at a folder
    /// in Files.app that will not open.
    public enum Unavailable: Error, LocalizedError {
        case sshNotBuilt
        case accessLoginRequired(String)
        case accessTokenUnreadable(String, underlying: String)
        case malformedHostname(String)
        case tailscaleUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .sshNotBuilt:
                return "This build of Sloop doesn't include SSH, so it can't browse files."
            case .accessLoginRequired(let hostname):
                return "Open Sloop and sign in to Cloudflare Access for \(hostname)."
            case .accessTokenUnreadable(let hostname, let underlying):
                return "Sloop couldn't read the stored Cloudflare Access token for "
                    + "\(hostname): \(underlying). Signing in again won't help until "
                    + "that's fixed."
            case .malformedHostname(let hostname):
                return hostname.isEmpty
                    ? "This host has no hostname. Fix it in Sloop."
                    : "\"\(hostname)\" isn't a valid hostname for Cloudflare Access. Fix it in Sloop."
            case .tailscaleUnavailable(let hostname):
                return "This build of Sloop can't join a tailnet on its own, so \(hostname) "
                    + "can't be reached from Files."
            }
        }
    }

    /// An SFTP client for `host`, or why there isn't one.
    ///
    /// - Parameters:
    ///   - hostKeyVerifier: `StrictHostKeyVerifier` from the extension. Never
    ///     an auto-accepting one: a process with no UI cannot run
    ///     trust-on-first-use, and silently pinning whatever answered is not a
    ///     lesser version of that — it is the absence of it.
    ///   - tailnetRole: which tsnet identity to dial with. The extension and
    ///     the app are separate devices on the tailnet.
    public static func sftp(host: SSHHost,
                            credential: Credential,
                            knownHosts: KnownHostsStore,
                            hostKeyVerifier: HostKeyVerifier,
                            accessTokens: AccessTokenStore,
                            tailnetRole: SloopStorage.TailnetRole,
                            authorizationPresenter: TailscaleAuthorizationPresenter)
    throws -> SFTPClient {
        #if canImport(CSSH)
        let dialer = try self.dialer(for: host, accessTokens: accessTokens,
                                     tailnetRole: tailnetRole,
                                     authorizationPresenter: authorizationPresenter)
        return LibSSH2SFTPClient(host: host, credential: credential, dialer: dialer,
                                 knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
        #else
        throw Unavailable.sshNotBuilt
        #endif
    }

    #if canImport(CSSH)
    private static func dialer(for host: SSHHost,
                               accessTokens: AccessTokenStore,
                               tailnetRole: SloopStorage.TailnetRole,
                               authorizationPresenter: TailscaleAuthorizationPresenter)
    throws -> Dialer {
        switch host.connectionMethod {
        case .direct:
            return TCPDialer(host: host.hostname, port: host.port)

        case .cloudflareAccess:
            guard let url = URL(string: "wss://\(host.hostname)"),
                  url.host()?.isEmpty == false else {
                throw Unavailable.malformedHostname(host.hostname)
            }
            let stored: AccessToken?
            do {
                stored = try accessTokens.validToken(for: host.hostname)
            } catch {
                // A keychain that refuses the read is not a missing login. No
                // number of browser sign-ins fixes a store that won't answer.
                throw Unavailable.accessTokenUnreadable(
                    host.hostname, underlying: error.localizedDescription)
            }
            guard let token = stored else {
                // The extension cannot open a browser, so this is where the
                // trail has to end — pointing at the one place it can continue.
                throw Unavailable.accessLoginRequired(host.hostname)
            }
            let dialer = CloudflareAccessDialer(url: url, hostname: host.hostname,
                                                token: token.raw)
            return TokenClearingDialer(wrapping: dialer, hostname: host.hostname,
                                       accessTokens: accessTokens)

        case .tailscale:
            #if SLOOP_TAILSCALE
            return TailscaleDialer(host: host.hostname, port: host.port,
                                   role: tailnetRole,
                                   presenter: authorizationPresenter)
            #else
            // Unlike the terminal's path, there is no "the Tailscale app's VPN
            // might be up" fallback worth taking here: the extension can run in
            // the background at any time, so a route that happens to exist now
            // is not a property the domain can rely on.
            throw Unavailable.tailscaleUnavailable(host.hostname)
            #endif
        }
    }
    #endif
}
