// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// Real libssh2-backed transport: a PTY shell channel on a `LibSSH2Connection`.
//
// This whole file compiles only when the `CSSH` module (the libssh2
// xcframework) is linked — see Docs/SSH.md. Until then the app uses
// `MessageTransport` via `TransportFactory`, so the project builds without it.
#if canImport(CSSH)
import Foundation
import CSSH
import SloopKit
#if canImport(Darwin)
import Darwin
#endif

final class LibSSH2Transport: Transport, SessionCommandRunner {
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: ((Error?) -> Void)?

    private let connection: LibSSH2Connection

    private let lock = NSLock()
    private var outbound: [UInt8] = []
    private var pendingResize: (cols: Int, rows: Int)?
    private var shouldClose = false

    /// A command to run on this session's *own* connection, and what to do with
    /// its output.
    ///
    /// SSH multiplexes channels over one connection, so reading the host's
    /// shell history costs a second channel rather than a second connection:
    /// no TCP connect, no second authentication, nothing for a host that
    /// rate-limits logins or caps MaxSessions to object to, and no second
    /// chance to prompt the user. The alternative — a fresh `CommandRunner` —
    /// pays all of that for output nobody sees.
    ///
    /// Run on the session thread with everything else, because a libssh2
    /// session is not safe to use from two threads at once.
    private var pendingCommand: (command: String, completion: (String?) -> Void)?

    init(host: SSHHost,
         credential: Credential,
         dialer: Dialer,
         knownHosts: KnownHostsStore,
         hostKeyVerifier: HostKeyVerifier = AutoAcceptHostKeyVerifier()) {
        connection = LibSSH2Connection(host: host, credential: credential, dialer: dialer,
                                       knownHosts: knownHosts,
                                       hostKeyVerifier: hostKeyVerifier)
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "org.szatmary.sloop.ssh"
        thread.stackSize = 1 << 20
        thread.start()
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        lock.lock(); outbound.append(contentsOf: bytes); lock.unlock()
    }

    func resize(cols: Int, rows: Int) {
        lock.lock(); pendingResize = (cols, rows); lock.unlock()
    }

    func close() {
        lock.lock(); shouldClose = true; lock.unlock()
    }

    /// Run a command on this connection and hand back what it printed, or nil
    /// if it couldn't run. One at a time; a request made while another is in
    /// flight replaces it, since the only caller asks once per session.
    func runOnSession(_ command: String, completion: @escaping (String?) -> Void) {
        lock.lock(); pendingCommand = (command, completion); lock.unlock()
    }

    // MARK: - Background connection

    private func finish(_ error: Error?) {
        DispatchQueue.main.async { [weak self] in self?.onClose?(error) }
    }

    private func run() {
        defer { connection.close() }

        let session: OpaquePointer
        do {
            session = try connection.open()
        } catch {
            return finish(error)
        }

        guard let channel = openShell(session) else {
            return finish(SSHError.channelFailure("could not open shell"))
        }
        defer {
            connection.retry { libssh2_channel_close(channel) }
            libssh2_channel_free(channel)
        }

        // Shell is up — the transport is now carrying data.
        DispatchQueue.main.async { [weak self] in self?.onOpen?() }

        eventLoop(session: session, channel: channel)
        finish(nil)
    }

    private func openShell(_ session: OpaquePointer) -> OpaquePointer? {
        var channel: OpaquePointer?
        while channel == nil {
            channel = "session".withCString {
                // The LIBSSH2_CHANNEL_WINDOW_DEFAULT/PACKET_DEFAULT macros don't
                // survive Swift's C importer ("structure not supported"), so use
                // their literal values from libssh2.h.
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
        guard let channel else { return nil }

        let term = "xterm-256color"
        var rc = term.withCString { termPtr in
            connection.retry {
                libssh2_channel_request_pty_ex(channel, termPtr, UInt32(term.utf8.count),
                                               nil, 0, 80, 24, 0, 0)
            }
        }
        guard rc == 0 else { return nil }

        rc = "shell".withCString { shellPtr in
            connection.retry {
                libssh2_channel_process_startup(channel, shellPtr, 5, nil, 0)
            }
        }
        return rc == 0 ? channel : nil
    }

    /// Open a second channel, run the queued command on it, and read it to the
    /// end. Blocking within this loop iteration is fine and simpler than
    /// interleaving: the command is a `tail` of a small file, and the terminal
    /// is idle at the moment it runs — it is fired once, just after the shell
    /// comes up, precisely so it costs nothing anybody is waiting on.
    private func runPendingCommand(session: OpaquePointer) {
        lock.lock()
        let request = pendingCommand
        pendingCommand = nil
        lock.unlock()
        guard let request else { return }

        var channel: OpaquePointer?
        while channel == nil {
            channel = "session".withCString {
                libssh2_channel_open_ex(session, $0, UInt32(7),
                                        UInt32(2 * 1024 * 1024),   // window default
                                        UInt32(32_768), nil, 0)    // packet default
            }
            if channel == nil {
                guard libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN else {
                    return request.completion(nil)
                }
                connection.waitSocket()
            }
        }
        guard let channel else { return request.completion(nil) }
        defer {
            connection.retry { libssh2_channel_close(channel) }
            libssh2_channel_free(channel)
        }

        let started = request.command.withCString { commandPtr in
            "exec".withCString { execPtr in
                connection.retry {
                    libssh2_channel_process_startup(channel, execPtr, 4,
                                                    commandPtr, UInt32(request.command.utf8.count))
                }
            }
        }
        guard started == 0 else { return request.completion(nil) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let read = buffer.withUnsafeMutableBytes { raw in
                libssh2_channel_read_ex(channel, 0, raw.bindMemory(to: CChar.self).baseAddress, raw.count)
            }
            if read > 0 {
                output.append(contentsOf: buffer[0..<read])
                // A history file is small, but a mis-set HISTFILE could point
                // at something that isn't. Stop rather than read a log forever.
                if output.count > 1 << 20 { break }
            } else if read == Int(LIBSSH2_ERROR_EAGAIN) {
                if libssh2_channel_eof(channel) != 0 { break }
                connection.waitSocket()
            } else {
                break
            }
        }
        request.completion(String(decoding: output, as: UTF8.self))
    }

    private func eventLoop(session: OpaquePointer, channel: OpaquePointer) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        while true {
            lock.lock()
            let closing = shouldClose
            let pending = outbound
            outbound.removeAll(keepingCapacity: true)
            let resize = pendingResize
            pendingResize = nil
            lock.unlock()

            if closing { return }

            runPendingCommand(session: session)

            // Flush queued keystrokes.
            if !pending.isEmpty {
                var offset = 0
                pending.withUnsafeBytes { raw in
                    let base = raw.bindMemory(to: CChar.self).baseAddress!
                    while offset < pending.count {
                        let n = libssh2_channel_write_ex(channel, 0, base + offset, pending.count - offset)
                        if n == Int(LIBSSH2_ERROR_EAGAIN) { break }
                        if n < 0 { return }
                        offset += n
                    }
                }
                if offset < pending.count {           // couldn't write it all; requeue remainder
                    lock.lock(); outbound.insert(contentsOf: pending[offset...], at: 0); lock.unlock()
                }
            }

            if let resize {
                _ = libssh2_channel_request_pty_size_ex(channel, Int32(resize.cols), Int32(resize.rows), 0, 0)
            }

            // Drain available output.
            var readData = false
            while true {
                let n = buffer.withUnsafeMutableBytes { raw in
                    // Use raw.count, not buffer.count — reading `buffer` here
                    // would be an overlapping (exclusive) access to the buffer.
                    libssh2_channel_read_ex(channel, 0, raw.bindMemory(to: CChar.self).baseAddress, raw.count)
                }
                if n > 0 {
                    onData?(ArraySlice(buffer[0..<n]))
                    readData = true
                } else if n == Int(LIBSSH2_ERROR_EAGAIN) {
                    break
                } else {                               // 0 (EOF) or error
                    if libssh2_channel_eof(channel) != 0 { return }
                    break
                }
            }

            if !readData { connection.waitSocket() }
        }
    }
}
#endif
