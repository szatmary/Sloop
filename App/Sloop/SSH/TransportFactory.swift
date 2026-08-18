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
    /// can't produce one right now (no Access token, unbuilt integration).
    private static func dialer(for host: SSHHost,
                               accessTokens: AccessTokenStore) -> Dialer? {
        switch host.connectionMethod {
        case .direct:
            return TCPDialer(host: host.hostname, port: host.port)
        case .cloudflareAccess:
            guard let url = URL(string: "wss://\(host.hostname)"),
                  let token = accessTokens.validToken(for: host.hostname) else {
                return nil
            }
            return CloudflareAccessDialer(url: url, hostname: host.hostname,
                                          token: token.raw)
        case .tailscale:
            return nil
        }
    }

    /// Why `dialer(for:)` returned nil, as terminal text. The host list's
    /// pre-connect gate normally prevents the Access case from being seen.
    private static func unavailable(for host: SSHHost) -> Transport {
        switch host.connectionMethod {
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
