// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit

/// Chooses a concrete `Transport` for a host. When the libssh2 xcframework is
/// linked (`CSSH` importable) it builds a real SSH connection over the dialer
/// `HostDialer` picks for the host's connection method; otherwise it returns a
/// `MessageTransport` explaining what's missing, so the app stays usable
/// during the libssh2 bring-up.
public enum TransportFactory {
    /// - Parameters:
    ///   - forwardedKeys: which of the user's keys this host's forwarded agent
    ///     may sign with. Empty — the default — forwards no agent at all.
    ///   - signConfirmer: who approves each signature. Defaults to denying,
    ///     which is the safe direction to fail: a caller that forgets to supply
    ///     one forwards nothing rather than signing unprompted.
    public static func ssh(host: SSHHost,
                           credential: Credential,
                           knownHosts: KnownHostsStore,
                           hostKeyVerifier: HostKeyVerifier,
                           accessTokens: AccessTokenStore,
                           authorizationPresenter: TailscaleAuthorizationPresenter,
                           forwardedKeys: [NamedKey] = [],
                           signConfirmer: AgentSignConfirming = DenyingSignConfirmer()) -> Transport {
        #if canImport(CSSH)
        do {
            return LibSSH2Transport(host: host, credential: credential,
                                    dialer: try dialer(for: host, accessTokens: accessTokens,
                                                       authorizationPresenter: authorizationPresenter),
                                    knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier,
                                    forwardedKeys: forwardedKeys,
                                    signConfirmer: signConfirmer)
        } catch let reason as DialerUnavailable {
            return MessageTransport(message: reason.terminalText)
        } catch {
            return MessageTransport(message: error.localizedDescription + "\r\n")
        }
        #else
        return MessageTransport(message:
            "SSH isn't built into this app yet.\r\n" +
            "Add Vendor/libssh2.xcframework and rebuild — see Docs/SSH.md.\r\n")
        #endif
    }

    /// The dialer for a host reached from the app, or why there isn't one.
    ///
    /// Not private: the Mosh probe needs the *same* answer for its exec
    /// channel. It used to make its own, hard-coded to `.direct` and a
    /// `TCPDialer`, so a tailnet host's probe refused to run and every Mosh
    /// session on one silently became SSH.
    ///
    /// Everything specific to being the app rather than the File Provider is
    /// here: the app's own tsnet identity, and the licence to ride the
    /// Tailscale app's system VPN when this build can't join a tailnet itself —
    /// the user is present and watching, which is exactly what a background
    /// extension cannot assume.
    static func dialer(for host: SSHHost,
                       accessTokens: AccessTokenStore,
                       authorizationPresenter: TailscaleAuthorizationPresenter) throws -> Dialer {
        try HostDialer.resolve(for: host, accessTokens: accessTokens, role: .app,
                               presenter: authorizationPresenter,
                               whenTailnetUnavailable: .systemVPNIfPresent)
    }
}
