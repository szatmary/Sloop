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

    /// Library keys this host's forwarded agent may sign with. Empty means the
    /// connection asks for no forwarding at all — `TransportFactory` has
    /// already resolved the host's selected names through
    /// `KeyLibrary.forwardedKeys` and dropped any that no longer exist, so an
    /// empty list here means empty in fact rather than empty in the host file.
    private let forwardedKeys: [NamedKey]
    private let signConfirmer: AgentSignConfirming
    /// Non-nil only while a forwarded agent is running. Touched solely on the
    /// session thread: built before the channel opens, serviced in the event
    /// loop, closed when the loop ends.
    private var forwardedAgent: ForwardedAgent?
    /// The live session, kept so `adoptAgentChannel` — which libssh2 calls back
    /// with nothing but the session and the abstract pointer — can hand the
    /// agent channel a way to wait on the socket.
    private var sshSession: OpaquePointer?

    /// Whether this connection asks the remote for forwarding at all.
    ///
    /// Internal rather than private so a test can assert the rule directly:
    /// the list `TransportFactory` resolved, not the host's raw selection, is
    /// what decides — a name whose key has since been deleted must not leave
    /// forwarding "on" with nothing behind it.
    var wantsForwarding: Bool { !forwardedKeys.isEmpty }

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

    private let endpoint: String

    init(host: SSHHost,
         credential: Credential,
         dialer: Dialer,
         knownHosts: KnownHostsStore,
         hostKeyVerifier: HostKeyVerifier = AutoAcceptHostKeyVerifier(),
         forwardedKeys: [NamedKey] = [],
         signConfirmer: AgentSignConfirming = DenyingSignConfirmer()) {
        connection = LibSSH2Connection(host: host, credential: credential, dialer: dialer,
                                       knownHosts: knownHosts,
                                       hostKeyVerifier: hostKeyVerifier)
        self.forwardedKeys = forwardedKeys
        self.signConfirmer = signConfirmer
        self.endpoint = "\(host.hostname):\(host.port)"
        // Must be set before `open()`: libssh2 takes the abstract pointer when
        // the session is created and never again.
        if wantsForwarding {
            connection.abstract = Unmanaged.passUnretained(self).toOpaque()
        }
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
        sshSession = session

        Self.startForwarding(
            wanted: wantsForwarding,
            buildAgent: {
                self.forwardedAgent = ForwardedAgent(
                    signer: AgentSigner(session: session, keys: self.forwardedKeys),
                    confirming: self.signConfirmer,
                    endpoint: self.endpoint)
            },
            registerAuthAgentCallback: {
                let authAgentCallback: @convention(c) (OpaquePointer?, OpaquePointer?,
                                                       UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Void = {
                    _, channel, abstract in
                    guard let channel, let box = abstract?.pointee else { return }
                    Unmanaged<LibSSH2Transport>.fromOpaque(box)
                        .takeUnretainedValue()
                        .adoptAgentChannel(channel)
                }
                _ = libssh2_session_callback_set2(
                    session, LIBSSH2_CALLBACK_AUTHAGENT,
                    unsafeBitCast(authAgentCallback, to: (@convention(c) () -> Void).self))
            })
        defer { forwardedAgent?.close() }

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
        let configured = Self.configureChannel(
            requestForwarding: forwardedAgent != nil,
            requestPTY: {
                term.withCString { termPtr in
                    connection.retry {
                        libssh2_channel_request_pty_ex(channel, termPtr, UInt32(term.utf8.count),
                                                       nil, 0, 80, 24, 0, 0)
                    }
                }
            },
            requestAuthAgent: {
                connection.retry { libssh2_channel_request_auth_agent(channel) }
            },
            startShell: {
                "shell".withCString { shellPtr in
                    connection.retry {
                        libssh2_channel_process_startup(channel, shellPtr, 5, nil, 0)
                    }
                }
            },
            onForwardingFailed: { [weak self] agentRC in
                let notice = "[sloop] agent forwarding refused by the server "
                    + "(rc=\(agentRC)) — continuing without it\r\n"
                self?.onData?(ArraySlice(Array(notice.utf8)))
            })
        return configured ? channel : nil
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

    /// Hand libssh2's newly opened agent channel to the forwarded agent.
    ///
    /// Called from libssh2 on the session thread, inside a channel-open it is
    /// already servicing, so it only stores the channel — everything else
    /// happens in the event loop.
    private func adoptAgentChannel(_ channel: OpaquePointer) {
        forwardedAgent?.adopt(LibSSH2AgentChannel(channel: channel) { [weak self] in
            self?.connection.waitSocket()
        })
    }

    /// PTY, then agent, then shell — OpenSSH's order, and the one servers
    /// expect. A refused agent request is not fatal: the server may simply
    /// have AllowAgentForwarding off, and a session without an agent is still
    /// a session. Returns false only when the PTY or the shell fails.
    static func configureChannel(requestForwarding: Bool,
                                 requestPTY: () -> Int32,
                                 requestAuthAgent: () -> Int32,
                                 startShell: () -> Int32,
                                 onForwardingFailed: (Int32) -> Void) -> Bool {
        guard requestPTY() == 0 else { return false }

        if requestForwarding {
            let agentRC = requestAuthAgent()
            if agentRC != 0 { onForwardingFailed(agentRC) }
        }
        return startShell() == 0
    }

    /// The agent must exist before the callback that hands channels to it is
    /// registered; libssh2 can invoke that callback as soon as it is set.
    static func startForwarding(wanted: Bool,
                                buildAgent: () -> Void,
                                registerAuthAgentCallback: () -> Void) {
        guard wanted else { return }
        buildAgent()
        registerAuthAgentCallback()
    }

    /// How many EAGAIN retries a "normal" agent-channel close gets before
    /// giving up. 5 attempts, each preceded by `waitSocket`'s own 200 ms poll
    /// cap, is up to 1 s worst case: enough for a cooperative peer's
    /// CHANNEL_CLOSE to arrive without turning a graceful teardown — which
    /// already means the tab is closing — into a noticeable hang.
    static let closeRetryAttempts = 5

    /// Close an agent channel, retrying only when the caller says the peer is
    /// worth waiting for.
    ///
    /// A teardown after a hostile or unresponsive peer must not wait at all:
    /// `service()` runs inside the event loop, so waiting there freezes the
    /// shell and stops `shouldClose` from ever being polled — the session
    /// becomes unrecoverable from the user's side.
    ///
    /// A pure function over closures rather than a live channel, so both
    /// policies are testable: a test can hand it an op that always reports
    /// EAGAIN and count the calls, which is the one thing that distinguishes
    /// "does not spin" from "spins forever".
    static func closeAttempt(retrying: Bool, maximumAttempts: Int,
                             op: () -> Int32, waitForSocket: () -> Void) {
        guard retrying else { _ = op(); return }
        for attempt in 0..<maximumAttempts {
            if op() != LIBSSH2_ERROR_EAGAIN { return }
            if attempt < maximumAttempts - 1 { waitForSocket() }
        }
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

            // Service the agent channel in the same pass as the shell.
            // `readData` absorbs its result so a loop that only had agent
            // traffic does not sleep with a reply already queued.
            if let forwardedAgent, forwardedAgent.service() { readData = true }

            if !readData { connection.waitSocket() }
        }
    }
}
#endif
