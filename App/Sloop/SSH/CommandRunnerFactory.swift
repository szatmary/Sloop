import Foundation
import SloopKit

/// Chooses a concrete `CommandRunner` for a host — the one-shot exec counterpart
/// to `TransportFactory`. When the libssh2 xcframework is linked (`CSSH`
/// importable) it returns the real `LibSSH2CommandRunner`; otherwise it returns
/// a runner that fails with a clear "SSH isn't built in yet" error, so callers
/// compile and behave predictably during the libssh2 bring-up.
enum CommandRunnerFactory {
    static func ssh(host: SSHHost,
                    credential: Credential,
                    knownHosts: KnownHostsStore,
                    hostKeyVerifier: HostKeyVerifier) -> CommandRunner {
        #if canImport(CSSH)
        return LibSSH2CommandRunner(host: host, credential: credential,
                                    knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
        #else
        return UnavailableCommandRunner()
        #endif
    }
}

/// A `CommandRunner` that always fails — used when SSH isn't compiled into the
/// app yet, so one-shot command callers have a well-defined fallback.
final class UnavailableCommandRunner: CommandRunner {
    func run(_ command: String, completion: @escaping (Result<CommandResult, Error>) -> Void) {
        completion(.failure(SSHError.notImplemented(
            "SSH isn't built into this app yet — add Vendor/libssh2.xcframework (see Docs/SSH.md).")))
    }
}
