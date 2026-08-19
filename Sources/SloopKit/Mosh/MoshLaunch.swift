// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

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

    /// The bootstrap, with anything else this session needs to ask the host run
    /// straight afterwards on the same channel.
    ///
    /// A Mosh session leaves no SSH connection behind — this exec is the only
    /// one there will ever be, and it closes as soon as mosh-server daemonizes.
    /// So a question asked here costs nothing extra (no second connection, no
    /// second authentication), and a question *not* asked here can never be
    /// asked at all.
    public static func script(extraCommands: [String]) -> String {
        MarkedCommandBatch.script(lead: bootstrapCommand, commands: extraCommands)
    }

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

/// What one run of the bootstrap produced: whether to proceed with Mosh, and
/// the output of everything else that rode along on the same channel.
public struct MoshBootstrapResult {
    public let startup: MoshStartup
    /// One entry per `MoshBootstrapper.extraCommands`, in order. `nil` where
    /// that command's output never came back — the exec failed, or the batch
    /// was cut short.
    public let extraOutputs: [String?]

    public init(startup: MoshStartup, extraOutputs: [String?]) {
        self.startup = startup
        self.extraOutputs = extraOutputs
    }
}

/// Runs the Mosh bootstrap over a `CommandRunner` (an SSH exec channel) and
/// reports whether to proceed with Mosh or fall back to SSH.
///
/// Injecting a `CommandRunner` keeps this testable with `MockCommandRunner` —
/// no network, no Mac.
public final class MoshBootstrapper {
    private let runner: CommandRunner

    /// Anything else the session wants to ask this host, run on the bootstrap
    /// channel right after `mosh-server`. Empty by default: a host nobody has a
    /// question for runs the bare bootstrap and nothing more.
    ///
    /// This is the only chance. Set it before `bootstrap(completion:)`.
    public var extraCommands: [String] = []

    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// Start `mosh-server`, classify the result, and hand back whatever the
    /// extra commands printed. The completion is invoked once, off the main
    /// thread, always with one entry per extra command — a caller left holding
    /// a completion that never fires waits forever.
    public func bootstrap(completion: @escaping (MoshBootstrapResult) -> Void) {
        let extras = extraCommands
        runner.run(MoshServer.script(extraCommands: extras)) { result in
            switch result {
            case .success(let output):
                // The markers are echoed to stdout, so that is what carries the
                // extra commands' outputs. stderr belongs to the banner: a
                // missing `mosh-server` shows up there as a shell error, and
                // that is what `interpret` reads. Folding stderr into the
                // stdout split instead is what let a login shell's warnings
                // trail into the last command's output — and be parsed as
                // somebody's shell history.
                let (banner, outputs) = MarkedCommandBatch.split(output.stdoutText,
                                                                 count: extras.count)
                completion(MoshBootstrapResult(
                    startup: MoshServer.interpret(banner + "\n" + output.stderrText),
                    extraOutputs: outputs))
            case .failure(let error):
                completion(MoshBootstrapResult(
                    startup: .unavailable(reason: error.localizedDescription),
                    extraOutputs: [String?](repeating: nil, count: extras.count)))
            }
        }
    }
}
