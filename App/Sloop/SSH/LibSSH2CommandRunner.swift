// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// Real libssh2-backed one-shot command runner (SSH *exec* channel).
//
// Like `LibSSH2Transport`, this whole file compiles only when the `CSSH`
// module (the libssh2 xcframework) is linked — see Docs/SSH.md. It implements
// the SloopKit `CommandRunner` contract: connect, run one command with no PTY
// and no interactive shell, capture stdout/stderr + exit status, disconnect.
//
// This is the basis for scripted one-shot commands and the planned Apple Watch
// command runner (run a command, get the result, drop the connection).
//
// The handshake/host-key/auth path lives in `LibSSH2Connection`, shared with
// the shell transport and the SFTP client. It was a hand-kept second copy here
// until that existed, on the theory that a typo could not then break the
// working shell transport — which also meant a *fix* could not reach it, and
// left the host-key state machine, the one thing standing between the user and
// a man-in-the-middle, duplicated.
#if canImport(CSSH)
import Foundation
import CSSH
import SloopKit
#if canImport(Darwin)
import Darwin
#endif

/// Runs a single command on a host over an SSH exec channel and returns its
/// captured output + exit status. Each `run` opens a fresh connection on a
/// background thread and tears it down when the command finishes.
final class LibSSH2CommandRunner: CommandRunner {
    /// A fresh connection per `run`: this is a one-shot runner, and holding an
    /// authenticated session open between commands would be a different
    /// contract than the one `CommandRunner` documents.
    private let makeConnection: () -> LibSSH2Connection

    init(host: SSHHost,
         credential: Credential,
         dialer: Dialer,
         knownHosts: KnownHostsStore,
         hostKeyVerifier: HostKeyVerifier = AutoAcceptHostKeyVerifier()) {
        makeConnection = {
            LibSSH2Connection(host: host, credential: credential, dialer: dialer,
                              knownHosts: knownHosts, hostKeyVerifier: hostKeyVerifier)
        }
    }

    func run(_ command: String, completion: @escaping (Result<CommandResult, Error>) -> Void) {
        let thread = Thread { [weak self] in
            guard let self else { return }
            completion(self.execute(command))
        }
        thread.name = "org.szatmary.sloop.ssh.exec"
        thread.stackSize = 1 << 20
        thread.start()
    }

    // MARK: - Background execution

    private func execute(_ command: String) -> Result<CommandResult, Error> {
        let connection = makeConnection()
        defer { connection.close() }

        let session: OpaquePointer
        do {
            session = try connection.open()
        } catch {
            return .failure(error)
        }

        // Open an exec channel — no PTY, no interactive shell.
        guard let channel = openExecChannel(session, connection) else {
            return .failure(SSHError.channelFailure("could not open exec channel"))
        }
        defer {
            connection.retry { libssh2_channel_close(channel) }
            libssh2_channel_free(channel)
        }

        let request = "exec"
        let startRC = request.withCString { reqPtr -> Int32 in
            command.withCString { cmdPtr in
                connection.retry {
                    libssh2_channel_process_startup(
                        channel, reqPtr, UInt32(request.utf8.count),
                        cmdPtr, UInt32(command.utf8.count))
                }
            }
        }
        guard startRC == 0 else {
            return .failure(SSHError.channelFailure("exec startup rc=\(startRC)"))
        }

        var stdout = Data()
        var stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        // Drain both streams until EOF. Stream 0 is stdout; the extended-data
        // stream 1 is stderr (SSH_EXTENDED_DATA_STDERR).
        while true {
            let n = read(channel, streamID: 0, into: &buffer)
            if n > 0 { stdout.append(contentsOf: buffer[0..<n]) }
            let m = read(channel, streamID: 1, into: &buffer)
            if m > 0 { stderr.append(contentsOf: buffer[0..<m]) }

            if n > 0 || m > 0 { continue }        // got data — keep draining
            if n == Int(LIBSSH2_ERROR_EAGAIN) || m == Int(LIBSSH2_ERROR_EAGAIN) {
                if libssh2_channel_eof(channel) != 0 { break }
                connection.waitSocket()
                continue
            }
            break                                  // both streams at EOF (0) or error
        }

        // Ask the server to close, then read the exit status.
        connection.retry { libssh2_channel_close(channel) }
        let exitStatus = libssh2_channel_get_exit_status(channel)

        return .success(CommandResult(stdout: stdout, stderr: stderr, exitStatus: exitStatus))
    }

    /// Read one chunk from `streamID` into `buffer`. Returns the libssh2 return
    /// value (byte count, 0 = EOF, or a negative error / EAGAIN).
    private func read(_ channel: OpaquePointer, streamID: Int32, into buffer: inout [UInt8]) -> Int {
        buffer.withUnsafeMutableBytes { raw in
            // Use raw.count, not buffer.count — reading `buffer` here would be an
            // overlapping (exclusive) access to the same buffer.
            libssh2_channel_read_ex(channel, streamID,
                                    raw.bindMemory(to: CChar.self).baseAddress, raw.count)
        }
    }

    private func openExecChannel(_ session: OpaquePointer,
                                 _ connection: LibSSH2Connection) -> OpaquePointer? {
        var channel: OpaquePointer?
        while channel == nil {
            channel = "session".withCString {
                // Literal window/packet defaults — the LIBSSH2_CHANNEL_*_DEFAULT
                // macros don't survive Swift's C importer.
                libssh2_channel_open_ex(session, $0, UInt32(7),
                                        UInt32(2 * 1024 * 1024),   // window default
                                        UInt32(32_768), nil, 0)    // packet default
            }
            if channel == nil {
                if libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN {
                    connection.waitSocket(); continue
                }
                return nil
            }
        }
        return channel
    }
}
#endif
