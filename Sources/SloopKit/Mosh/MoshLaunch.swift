import Foundation

/// The outcome of trying to start Mosh on a host over SSH.
///
/// This is the "prefer Mosh, fall back to SSH" decision: run `mosh-server` on
/// the remote and either get a Mosh handshake back, or discover Mosh isn't
/// usable there and stay on the SSH shell we already have.
public enum MoshStartup: Equatable {
    /// `mosh-server` started and returned its handshake — proceed to the Mosh
    /// UDP/SSP session.
    case connect(MoshBootstrap)
    /// Mosh couldn't start (not installed, wrong locale, etc.) — fall back to a
    /// normal SSH shell. `reason` is a short, user-facing explanation.
    case unavailable(reason: String)
}

/// Starting `mosh-server` over an SSH exec channel and interpreting its output.
///
/// Sloop bootstraps Mosh the same way the upstream client does: it's already
/// SSHed in, so it runs `mosh-server` and reads the reply. Unlike upstream Mosh
/// — which errors out if `mosh-server` is missing — Sloop turns a missing server
/// into a graceful SSH fallback (`MoshStartup.unavailable`), because it still
/// holds a live SSH connection.
public enum MoshServer {
    /// The command run over SSH to start a Mosh server. `mosh-server` needs a
    /// UTF-8 locale or it refuses to start, so one is forced here. (A later
    /// increment can forward the client's own locale instead.)
    public static let bootstrapCommand = "mosh-server new -s -c 256 -l LANG=en_US.UTF-8"

    /// Classify the combined stdout/stderr of the bootstrap command.
    public static func interpret(_ output: String) -> MoshStartup {
        if let bootstrap = MoshBootstrap(serverBanner: output) {
            return .connect(bootstrap)
        }
        let lowered = output.lowercased()
        if lowered.contains("command not found")
            || lowered.contains("no such file")
            || lowered.contains("not found") {
            return .unavailable(reason: "Mosh isn't installed on the server")
        }
        if lowered.contains("utf-8") || lowered.contains("locale") {
            return .unavailable(reason: "The server's locale isn't UTF-8, which Mosh requires")
        }
        return .unavailable(reason: "mosh-server didn't start")
    }
}

/// Runs the Mosh bootstrap over a `CommandRunner` (an SSH exec channel) and
/// reports whether to proceed with Mosh or fall back to SSH.
///
/// Injecting a `CommandRunner` keeps this testable with `MockCommandRunner` —
/// no network, no Mac.
public final class MoshBootstrapper {
    private let runner: CommandRunner

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// Start `mosh-server` and classify the result. The completion is invoked
    /// once, off the main thread.
    public func bootstrap(completion: @escaping (MoshStartup) -> Void) {
        runner.run(MoshServer.bootstrapCommand) { result in
            switch result {
            case .success(let output):
                // mosh-server prints its handshake on stdout and errors on
                // stderr; a missing binary shows up as a shell error on stderr.
                let combined = output.stdoutText + "\n" + output.stderrText
                completion(MoshServer.interpret(combined))
            case .failure(let error):
                completion(.unavailable(reason: error.localizedDescription))
            }
        }
    }
}
