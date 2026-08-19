// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// Real libssh2-backed transport.
//
// This whole file compiles only when the `CSSH` module (the libssh2
// xcframework) is linked — see Docs/SSH.md. Until then the app uses
// `MessageTransport` via `TransportFactory`, so the project builds without it.
//
// ⚠️ Written against the stable libssh2 C API but NOT yet compiled in this repo
// (no Xcode/iOS SDK was available when it was authored). Expect a fix-up pass on
// first build — mainly around exact constant/typedef spellings the Swift
// importer produces. The structure (non-blocking session + poll loop) is the
// intended design.
#if canImport(CSSH)
import Foundation
import CSSH
import SloopKit
#if canImport(Darwin)
import Darwin
#endif

final class LibSSH2Transport: Transport {
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: ((Error?) -> Void)?

    private let host: SSHHost
    private let credential: Credential
    private let knownHosts: KnownHostsStore
    private let hostKeyVerifier: HostKeyVerifier
    private let dialer: Dialer
    private let forwardedKeys: [NamedKey]
    private let signConfirmer: AgentSignConfirming

    private let lock = NSLock()
    private var outbound: [UInt8] = []
    private var pendingResize: (cols: Int, rows: Int)?
    private var shouldClose = false

    /// Non-nil only while a forwarded agent is running. Touched solely on the
    /// SSH thread — the callback that sets it is invoked by libssh2 from
    /// inside packet processing, which happens on that same thread.
    private var forwardedAgent: ForwardedAgent?

    /// Set once in `run()`, right after the socket is dialed and the session
    /// is created. Exists so `adoptAgentChannel` — invoked from the AUTHAGENT
    /// callback with only the new channel in hand, since that's all libssh2
    /// passes it — can still hand `LibSSH2AgentChannel` a way to retry its
    /// close against EAGAIN, the same way the shell channel's own teardown
    /// does, without threading session/sock through the callback itself.
    private var sshSession: OpaquePointer?
    private var sshSocket: Int32 = -1

    /// Whether this connection asks the remote for agent forwarding at all.
    /// Driven only by `forwardedKeys` — the list `TransportFactory` already
    /// resolved through `KeyLibrary.forwardedKeys`, which drops any selected
    /// name that no longer resolves to a library key — and never by
    /// `host.forwardsAgent`, which reflects the raw selected NAMES and stays
    /// true even after every one of them stops resolving to anything. The two
    /// disagreeing is exactly how a forwarded-agent channel could get opened
    /// with nothing listening for it: `forwardedAgent` (below) would be nil
    /// because there was nothing to build a signer from, `adoptAgentChannel`
    /// would silently discard the channel `host.forwardsAgent` asked sshd to
    /// open, and the remote would block forever on a channel nobody answers.
    /// Internal rather than private so a test can construct a transport with
    /// a `host` that disagrees with `forwardedKeys` and confirm this reads
    /// the latter — the actual bug required a live connection to reach the
    /// code that used to get this wrong, but this decision is pure over
    /// `forwardedKeys` and needs neither a socket nor a session to check.
    var wantsForwarding: Bool { !forwardedKeys.isEmpty }

    init(host: SSHHost,
         credential: Credential,
         dialer: Dialer,
         knownHosts: KnownHostsStore,
         hostKeyVerifier: HostKeyVerifier = AutoAcceptHostKeyVerifier(),
         forwardedKeys: [NamedKey] = [],
         signConfirmer: AgentSignConfirming = AgentSignPrompter.shared) {
        self.host = host
        self.credential = credential
        self.dialer = dialer
        self.knownHosts = knownHosts
        self.hostKeyVerifier = hostKeyVerifier
        self.forwardedKeys = forwardedKeys
        self.signConfirmer = signConfirmer
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

    // MARK: - Background connection

    private func finish(_ error: Error?) {
        DispatchQueue.main.async { [weak self] in self?.onClose?(error) }
    }

    private func run() {
        guard libssh2_init(0) == 0 else {
            return finish(SSHError.connectionFailed("libssh2_init failed"))
        }
        defer { libssh2_exit() }

        let sock: Int32
        do {
            sock = try dialer.dial()
        } catch {
            return finish(error)
        }
        defer { Darwin.close(sock) }
        sshSocket = sock

        // The fourth argument is libssh2's "abstract" slot — an opaque void*
        // it stores on the session and hands back, unexamined, to callbacks
        // registered on that session. Stashing `self` there is how the
        // AUTHAGENT callback below (a bare C function pointer, so it can't
        // capture anything) finds its way back to this transport.
        // `passUnretained` rather than a leak-forever `passRetained`: this
        // very `run()` frame outlives the session (see the `defer` below),
        // so `self` is guaranteed alive for as long as the session — and
        // therefore the callback — can possibly fire.
        guard let session = libssh2_session_init_ex(
            nil, nil, nil, Unmanaged.passUnretained(self).toOpaque()) else {
            return finish(SSHError.connectionFailed("session_init failed"))
        }
        defer {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(session)
        }
        libssh2_session_set_blocking(session, 0)
        sshSession = session

        // A remote can open the forwarded-agent channel at any point after
        // auth completes, so this has to be registered before the handshake
        // — not just before openShell, where forwarding is requested — or an
        // early request could arrive with nothing listening for it.
        //
        // The AUTHAGENT callback's real type is
        //   (LIBSSH2_SESSION *, LIBSSH2_CHANNEL *, void **) -> Void
        // but callback_set2 takes a generic void(*)(void), so the cast below
        // is required and is the same one libssh2's own examples use.
        let authAgentCallback: @convention(c) (OpaquePointer?, OpaquePointer?,
                                               UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Void = {
            _, channel, abstract in
            // Runs inside libssh2 packet processing, on the SSH thread that
            // is already inside a libssh2_channel_read_ex call — so this
            // does the absolute minimum and returns. No read, write, sign,
            // or prompt: any of those would re-enter libssh2 from inside
            // libssh2. Servicing the newly-adopted channel happens on
            // eventLoop's own next pass, off this callback's stack.
            guard let channel,
                  let box = abstract?.pointee else { return }
            let transport = Unmanaged<LibSSH2Transport>.fromOpaque(box).takeUnretainedValue()
            transport.adoptAgentChannel(channel)
        }
        _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_AUTHAGENT,
                                          unsafeBitCast(authAgentCallback, to: (@convention(c) () -> Void).self))

        // Handshake
        let rc = retry(session, sock) { libssh2_session_handshake(session, sock) }
        guard rc == 0 else { return finish(SSHError.connectionFailed("handshake rc=\(rc)")) }

        // Host-key verification (trust-on-first-use)
        if let error = verifyHostKey(session) { return finish(error) }

        // Authenticate
        if let error = authenticate(session, sock) { return finish(error) }

        // The agent needs a session that has finished authenticating —
        // AgentSigner derives identities from it — and must exist before
        // openShell, which is where forwarding is actually requested.
        if wantsForwarding {
            forwardedAgent = ForwardedAgent(
                signer: AgentSigner(session: session, keys: forwardedKeys),
                confirming: signConfirmer,
                endpoint: "\(host.hostname):\(host.port)")
        }

        // Open a shell channel with a PTY
        guard let channel = openShell(session, sock) else {
            return finish(SSHError.channelFailure("could not open shell"))
        }
        defer {
            // Tear down the agent channel alongside the shell channel rather
            // than leaving its fate to whatever libssh2_session_free happens
            // to do with a channel nobody explicitly closed.
            forwardedAgent?.close()
            _ = retry(session, sock) { libssh2_channel_close(channel) }
            libssh2_channel_free(channel)
        }

        // Shell is up — the transport is now carrying data.
        DispatchQueue.main.async { [weak self] in self?.onOpen?() }

        eventLoop(session: session, channel: channel, sock: sock)
        finish(nil)
    }

    private func verifyHostKey(_ session: OpaquePointer) -> Error? {
        var keyLen = 0
        var keyType: Int32 = 0
        guard libssh2_session_hostkey(session, &keyLen, &keyType) != nil else {
            return SSHError.connectionFailed("no host key")
        }
        guard let hashPtr = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256) else {
            return SSHError.connectionFailed("no host-key hash")
        }
        let fingerprint = Data(bytes: hashPtr, count: 32).base64EncodedString()
        let typeName = hostKeyTypeName(keyType)
        let endpoint = KnownHostsStore.endpoint(host: host.hostname, port: host.port)

        switch knownHosts.status(endpoint: endpoint, keyType: typeName, fingerprint: fingerprint) {
        case .match:
            return nil
        case .unknown:
            // Trust-on-first-use: ask the verifier (an interactive one prompts
            // the user). Remember the key only if trusted; otherwise refuse.
            guard hostKeyVerifier.shouldTrust(endpoint: endpoint,
                                              keyType: typeName,
                                              fingerprint: fingerprint) else {
                return SSHError.connectionFailed("host key for \(endpoint) was not trusted")
            }
            do {
                try knownHosts.remember(endpoint: endpoint, keyType: typeName,
                                        fingerprint: fingerprint)
            } catch {
                // Refuse rather than proceed on an unpinned key: a silent
                // failure here means the next connection sees this host as
                // new again, with no record of what was trusted.
                return SSHError.connectionFailed(
                    "couldn't record the host key for \(endpoint): \(error.localizedDescription)")
            }
            return nil
        case .mismatch:
            // A record we could not read is reported as .mismatch so it fails
            // closed, but it is not a changed key: there is no previous
            // fingerprint to show, so say what actually happened.
            if knownHosts.isUnreadable(endpoint: endpoint) {
                return SSHError.connectionFailed(
                    "the stored host key for \(endpoint) is damaged and cannot be read — "
                    + "verify the key out of band, then re-add the host to trust it again")
            }
            // The endpoint is known but its key changed — a possible MITM. Ask
            // the verifier (an interactive one shows a strong warning). Replace
            // the stored key only if the user explicitly accepts.
            let previous = knownHosts.recorded(endpoint: endpoint)?.fingerprint ?? "unknown"
            guard hostKeyVerifier.shouldTrustChangedKey(endpoint: endpoint,
                                                        keyType: typeName,
                                                        fingerprint: fingerprint,
                                                        previousFingerprint: previous) else {
                return SSHError.connectionFailed("host key changed for \(endpoint) — refusing to connect")
            }
            do {
                try knownHosts.remember(endpoint: endpoint, keyType: typeName,
                                        fingerprint: fingerprint)
            } catch {
                // Refuse rather than proceed on an unpinned key: a silent
                // failure here means the next connection sees this host as
                // new again, with no record of what was trusted.
                return SSHError.connectionFailed(
                    "couldn't record the host key for \(endpoint): \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func authenticate(_ session: OpaquePointer, _ sock: Int32) -> Error? {
        let user = host.username

        if let key = credential.privateKeyPEM {
            // Supply the public key when we have it, and let the crypto
            // backend derive it otherwise. OpenSSL derives it happily; the
            // mbedTLS backend this project used previously could not, which
            // is why keys carry one — see Credential.publicKey.
            let rc = withOptionalCString(credential.publicKey) { pubPtr, pubLen in
                user.withCString { userPtr -> Int32 in
                    key.withCString { keyPtr in
                        (credential.passphrase ?? "").withCString { passPtr in
                            retry(session, sock) {
                                libssh2_userauth_publickey_frommemory(
                                    session, userPtr, user.utf8.count,
                                    pubPtr, pubLen,
                                    keyPtr, key.utf8.count,
                                    passPtr)
                            }
                        }
                    }
                }
            }
            return rc == 0 ? nil : SSHError.authenticationFailed(
                "server rejected the private key for '\(user)' — \(libssh2LastError(session))")
        }

        if let password = credential.password {
            let rc = user.withCString { userPtr -> Int32 in
                password.withCString { passPtr in
                    retry(session, sock) {
                        libssh2_userauth_password_ex(
                            session, userPtr, UInt32(user.utf8.count),
                            passPtr, UInt32(password.utf8.count), nil)
                    }
                }
            }
            return rc == 0 ? nil : SSHError.authenticationFailed(
                "server rejected the password for '\(user)' — \(libssh2LastError(session))")
        }

        return SSHError.authenticationFailed(
            "no password or private key is configured for this host — edit it and " +
            "choose a key from the library, or enter a password")
    }

    private func openShell(_ session: OpaquePointer, _ sock: Int32) -> OpaquePointer? {
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
                    waitSocket(sock, session); continue
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
                    retry(session, sock) {
                        libssh2_channel_request_pty_ex(channel, termPtr, UInt32(term.utf8.count),
                                                       nil, 0, 80, 24, 0, 0)
                    }
                }
            },
            requestAuthAgent: {
                retry(session, sock) { libssh2_channel_request_auth_agent(channel) }
            },
            startShell: {
                "shell".withCString { shellPtr in
                    retry(session, sock) {
                        libssh2_channel_process_startup(channel, shellPtr, 5, nil, 0)
                    }
                }
            },
            onForwardingFailed: { agentRC in
                // Not fatal: a working shell that can't forward beats no
                // shell at all. A server without
                // "auth-agent-req@openssh.com" support is common enough that
                // failing the whole connection over it would be wrong.
                let message = "sloop: agent forwarding request failed (rc=\(agentRC)) for " +
                    "\(host.hostname) — continuing without it\n"
                FileHandle.standardError.write(Data(message.utf8))
            })

        return configured ? channel : nil
    }

    /// The three channel-setup requests `openShell` issues, in the order that
    /// makes agent forwarding actually work against real OpenSSH: PTY, then
    /// (if wanted) the auth-agent request, then the shell itself — never the
    /// reverse.
    ///
    /// sshd only honours `auth-agent-req@openssh.com` while the channel is
    /// still `SSH_CHANNEL_LARVAL` (`session_input_channel_req`). Its own
    /// `session_shell_req` — which our shell request triggers — calls
    /// `channel_set_fds` and flips the channel to `SSH_CHANNEL_OPEN` before
    /// returning, and that same call is what bakes (the absent)
    /// `SSH_AUTH_SOCK` into the child's environment. So asking for forwarding
    /// after the shell request is not merely late: sshd has already refused
    /// it (`CHANNEL_FAILURE`), and even a hypothetical late success could
    /// never reach the shell process, whose environment was fixed the moment
    /// it started.
    ///
    /// This exists as its own function — no `self`, no session, no channel —
    /// purely so that ordering is unit-testable. Nothing in a unit test can
    /// observe sshd's LARVAL/OPEN state machine or its child's environment,
    /// but a test *can* observe which of `requestAuthAgent` / `startShell` a
    /// fake pair of closures sees called first, which is exactly what proves
    /// this function still asks in the right order after any future edit.
    ///
    /// Returns false (without calling `startShell`) if the PTY request
    /// fails. A forwarding failure is reported via `onForwardingFailed` and
    /// is never fatal — `startShell` still runs.
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

    /// Invoked by the AUTHAGENT C callback with the channel libssh2 just
    /// opened for the remote's forwarding request. Only ever called on the
    /// SSH thread, same as everything else in this class — `eventLoop`
    /// services the newly-adopted channel on its own next pass.
    private func adoptAgentChannel(_ channel: OpaquePointer) {
        forwardedAgent?.adopt(LibSSH2AgentChannel(channel: channel) { [weak self] op in
            // Lets the agent channel retry its close against EAGAIN through
            // the exact same helper the shell channel's own teardown uses,
            // without `LibSSH2AgentChannel` needing to know what a
            // `LibSSH2Transport` is. If the transport is already gone there
            // is no session left to retry against, so just take the one
            // answer `op()` gives.
            guard let self, let session = self.sshSession else { return op() }
            return self.retry(session, self.sshSocket, op)
        })
    }

    private func eventLoop(session: OpaquePointer, channel: OpaquePointer, sock: Int32) {
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
            // traffic does not sleep for 200 ms with a reply already queued.
            if let forwardedAgent, forwardedAgent.service() { readData = true }

            if !readData { waitSocket(sock, session) }
        }
    }

    // MARK: - libssh2 non-blocking helpers

    /// Retry an int-returning libssh2 call until it stops returning EAGAIN.
    private func retry(_ session: OpaquePointer, _ sock: Int32, _ op: () -> Int32) -> Int32 {
        while true {
            let rc = op()
            if rc == LIBSSH2_ERROR_EAGAIN { waitSocket(sock, session); continue }
            return rc
        }
    }

    /// Block until the socket is ready in the direction libssh2 is waiting on.
    private func waitSocket(_ sock: Int32, _ session: OpaquePointer) {
        var pfd = pollfd(fd: sock, events: 0, revents: 0)
        let directions = libssh2_session_block_directions(session)
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { pfd.events |= Int16(POLLIN) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { pfd.events |= Int16(POLLOUT) }
        if pfd.events == 0 { pfd.events = Int16(POLLIN) }
        _ = poll(&pfd, 1, 200)   // 200 ms cap so close/resize stay responsive
    }

    private func hostKeyTypeName(_ type: Int32) -> String {
        switch type {
        case LIBSSH2_HOSTKEY_TYPE_RSA:     return "ssh-rsa"
        case LIBSSH2_HOSTKEY_TYPE_DSS:     return "ssh-dss"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return "ecdsa-sha2-nistp256"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return "ecdsa-sha2-nistp384"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return "ecdsa-sha2-nistp521"
        case LIBSSH2_HOSTKEY_TYPE_ED25519: return "ssh-ed25519"
        default: return "unknown"
        }
    }
}
#endif
