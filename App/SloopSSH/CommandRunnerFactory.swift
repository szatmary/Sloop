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
                    hostKeyVerifier: HostKeyVerifier) -> CommandRunner {
        #if canImport(CSSH)
        // A tunneled host must never get a runner that dials its hostname
        // directly — that would bypass the tunnel and send credentials to
        // whatever answers on the host's public port 22. Today the only
        // caller (the Mosh probe, via HostListModel.connect) already limits
        // itself to `.direct` hosts, but that guard lives in a different
        // file; this factory shouldn't depend on it staying that way.
        guard host.connectionMethod == .direct else {
            return UnavailableCommandRunner(message:
                "Command execution isn't available for tunneled hosts — it would bypass the tunnel.")
        }
        return LibSSH2CommandRunner(host: host, credential: credential,
                                    dialer: TCPDialer(host: host.hostname, port: host.port),
                                    knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
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
