// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit

/// Chooses a concrete `CommandRunner` for a host — the one-shot exec counterpart
/// to `TransportFactory`. When the libssh2 xcframework is linked (`CSSH`
/// importable) it returns the real `LibSSH2CommandRunner`; otherwise it returns
/// a runner that fails with a clear "SSH isn't built in yet" error, so callers
/// compile and behave predictably during the libssh2 bring-up.
public enum CommandRunnerFactory {
    public static func ssh(host: SSHHost,
                    credential: Credential,
                    knownHosts: KnownHostsStore,
                    hostKeyVerifier: HostKeyVerifier,
                    accessTokens: AccessTokenStore,
                    authorizationPresenter: TailscaleAuthorizationPresenter
                        = NoAuthorizationPresenter()) -> CommandRunner {
        #if canImport(CSSH)
        // The same dialer the shell would use — never a direct TCP connect to a
        // tunneled host's hostname, which would bypass the tunnel and offer the
        // credential to whatever answers on its public port 22. Asking
        // `TransportFactory` rather than deciding again here is what stops the
        // two from drifting: they did, and a tailnet host's Mosh probe refused
        // to run at all, so every Mosh session over the tailnet quietly became
        // an SSH one.
        switch TransportFactory.dialer(for: host, accessTokens: accessTokens,
                                       authorizationPresenter: authorizationPresenter) {
        case .ready(let dialer):
            return LibSSH2CommandRunner(host: host, credential: credential,
                                        dialer: dialer,
                                        knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
        case .unavailable(let reason):
            return UnavailableCommandRunner(message: reason)
        }
        #else
        return UnavailableCommandRunner()
        #endif
    }
}

/// A `CommandRunner` that always fails — used when SSH isn't compiled into the
/// app yet, or when the requested host can't safely get a runner from this
/// factory, so one-shot command callers have a well-defined fallback.
public final class UnavailableCommandRunner: CommandRunner {
    private let message: String

    public init(message: String = "SSH isn't built into this app yet — add Vendor/libssh2.xcframework (see Docs/SSH.md).") {
        self.message = message
    }

    public func run(_ command: String, completion: @escaping (Result<CommandResult, Error>) -> Void) {
        completion(.failure(SSHError.notImplemented(message)))
    }
}
