import Foundation

/// The outcome of running a single remote command over an SSH exec channel.
public struct CommandResult: Equatable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitStatus: Int32

    public init(stdout: Data = Data(), stderr: Data = Data(), exitStatus: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitStatus == 0 }
}

/// Runs a single command on a host over SSH — an *exec* channel: no PTY, no
/// interactive shell — and returns its captured output and exit status.
///
/// The libssh2-backed implementation lives in the app layer; this protocol keeps
/// the contract testable in SloopKit and is the basis for one-shot commands (and
/// the planned Apple Watch command runner, which needs exactly this: run a
/// command, get the result, disconnect).
public protocol CommandRunner {
    /// Run `command`. The completion is invoked once, off the main thread.
    func run(_ command: String, completion: @escaping (Result<CommandResult, Error>) -> Void)
}

/// A canned `CommandRunner` for tests and previews — returns a fixed result with
/// no network.
public final class MockCommandRunner: CommandRunner {
    private let result: Result<CommandResult, Error>

    public init(_ result: Result<CommandResult, Error>) {
        self.result = result
    }

    public convenience init(stdout: String = "", stderr: String = "", exitStatus: Int32 = 0) {
        self.init(.success(CommandResult(stdout: Data(stdout.utf8),
                                         stderr: Data(stderr.utf8),
                                         exitStatus: exitStatus)))
    }

    public func run(_ command: String, completion: @escaping (Result<CommandResult, Error>) -> Void) {
        completion(result)
    }
}
