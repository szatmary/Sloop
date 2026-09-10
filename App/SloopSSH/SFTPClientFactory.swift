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
    /// Why a host has no SFTP client at all — as opposed to `DialerUnavailable`,
    /// which is why it can't be *reached*. One case, because that is how many
    /// reasons there are that aren't about the connection.
    public enum Unavailable: Error, LocalizedError, UserActionRequiredError {
        case sshNotBuilt

        public var errorDescription: String? {
            switch self {
            case .sshNotBuilt:
                return "This build of Sloop doesn't include SSH, so it can't browse files."
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
        // The same decision the terminal makes, differing only where it must:
        // this process gets its own tailnet identity, and no licence to ride a
        // system VPN it cannot know will still be up next time the system wakes
        // it. Every other reason a host can't be dialed is `DialerUnavailable`'s
        // to state, and `FileProviderError` turns it into the "go to Sloop"
        // failure Files.app shows on the folder.
        let dialer = try HostDialer.resolve(for: host, accessTokens: accessTokens,
                                            role: tailnetRole,
                                            presenter: authorizationPresenter,
                                            whenTailnetUnavailable: .refuse)
        return LibSSH2SFTPClient(host: host, credential: credential, dialer: dialer,
                                 knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
        #else
        throw Unavailable.sshNotBuilt
        #endif
    }
}
