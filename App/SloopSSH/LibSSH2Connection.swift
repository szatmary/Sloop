// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if canImport(CSSH)
import Foundation
import CSSH
import SloopKit
#if canImport(Darwin)
import Darwin
#endif

/// An authenticated libssh2 session: dial, handshake, host-key check, auth.
///
/// Everything Sloop does over SSH begins with exactly these four steps and
/// differs only in what it opens afterwards — a PTY shell
/// (`LibSSH2Transport`), an exec channel (`LibSSH2CommandRunner`), or the SFTP
/// subsystem (`LibSSH2SFTPClient`). They were written out twice before this
/// existed, including the whole host-key state machine, which is the one piece
/// of code in Sloop that stands between the user and a man-in-the-middle. Two
/// copies of that is one too many: a fix to either was a fix to only half the
/// app, and nothing made the halves diverge loudly.
///
/// Blocking, and called from a worker thread. The session is non-blocking
/// underneath; `retry` and `waitSocket` hide that, turning EAGAIN into a poll.
final class LibSSH2Connection {
    private let host: SSHHost
    private let credential: Credential
    private let dialer: Dialer
    private let knownHosts: KnownHostsStore
    private let hostKeyVerifier: HostKeyVerifier

    private var session: OpaquePointer?
    private var socket: Int32 = -1

    /// Handed to `libssh2_session_init_ex` as the session's `abstract`, which
    /// is the only context libssh2 gives back to a session callback. Agent
    /// forwarding needs it: the AUTHAGENT callback fires with nothing but the
    /// session and this pointer, and has to find its way back to the transport
    /// that owns the forwarded agent. Set before `open()`, unused otherwise.
    var abstract: UnsafeMutableRawPointer?

    /// Asked before every EAGAIN wait, so an owner that has been closed can
    /// stop a connection that has not finished starting.
    ///
    /// Defaults to "never": the SFTP client and the command runner drive their
    /// own lifecycles and are not changed by this. `LibSSH2Transport` sets it
    /// to its own `shouldClose`, which used to be read only inside the event
    /// loop — a place a stuck handshake never reaches.
    var isCancelled: () -> Bool = { false }

    /// A ceiling on the phases that run before the event loop, set for the
    /// duration of `open()` so handshake, host-key check and authentication
    /// share one budget rather than each getting its own.
    ///
    /// A port that completes TCP and then says nothing — a tarpit, a non-SSH
    /// service, a middlebox holding the connection open — otherwise leaves
    /// them polling at 200 ms a turn for the life of the process, holding a
    /// thread, a socket and the credential strings. OpenSSH's own
    /// `LoginGraceTime` defaults to 120 s; this is the client side of the same
    /// idea, with room for a slow link and a hardware token.
    static let connectPhaseTimeout: TimeInterval = 60

    private var connectDeadline: Date?

    /// libssh2's global init, run exactly once per process.
    ///
    init(host: SSHHost,
         credential: Credential,
         dialer: Dialer,
         knownHosts: KnownHostsStore,
         hostKeyVerifier: HostKeyVerifier) {
        self.host = host
        self.credential = credential
        self.dialer = dialer
        self.knownHosts = knownHosts
        self.hostKeyVerifier = hostKeyVerifier
    }

    deinit { close() }

    /// Dials, handshakes, verifies the host key and authenticates.
    ///
    /// - Returns: the live session, ready for a channel or a subsystem. Valid
    ///   until `close()`.
    @discardableResult
    func open() throws -> OpaquePointer {
        guard LibSSH2Library.isReady else {
            throw SSHError.connectionFailed("libssh2_init failed")
        }

        socket = try dialer.dial()

        guard let session = libssh2_session_init_ex(nil, nil, nil, abstract) else {
            close()
            throw SSHError.connectionFailed("session_init failed")
        }
        self.session = session
        libssh2_session_set_blocking(session, 0)

        connectDeadline = Date().addingTimeInterval(Self.connectPhaseTimeout)
        defer { connectDeadline = nil }

        do {
            let rc = retry { libssh2_session_handshake(session, self.socket) }
            guard rc == 0 else {
                // libssh2's own reason, not just the code: "handshake rc=-9"
                // reads identically whether the server is not an SSH server,
                // the tab was closed, or nothing ever answered.
                throw SSHError.connectionFailed("handshake failed: \(lastError) [libssh2 \(rc)]")
            }
            if let error = verifyHostKey(session) { throw error }
            if let error = authenticate(session) { throw error }
        } catch {
            close()
            throw error
        }
        return session
    }

    /// Idempotent, so both `deinit` and an explicit close are safe.
    func close() {
        if let session {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(session)
            self.session = nil
        }
        if socket >= 0 {
            Darwin.close(socket)
            socket = -1
        }
    }

    // MARK: - Non-blocking helpers

    /// What an EAGAIN loop should do after one attempt.
    enum RetryStep: Equatable {
        /// libssh2 answered; this is the result.
        case finished(Int32)
        /// Stop and report a timeout: the owner cancelled, or the deadline
        /// passed.
        case giveUp
        /// Wait for the socket and try again.
        case wait
    }

    /// Decides whether an EAGAIN loop may go round again.
    ///
    /// Pulled out because the loops it governs need a live server — or a live
    /// tarpit — to exercise, which is how a connection that could never be
    /// closed passed every test.
    static func retryStep(rc: Int32, isCancelled: Bool, isPastDeadline: Bool) -> RetryStep {
        // A result already in hand is kept even if the tab closed or the
        // deadline passed while the call was running: discarding it would fail
        // a connection that had in fact just succeeded.
        guard rc == LIBSSH2_ERROR_EAGAIN else { return .finished(rc) }
        return (isCancelled || isPastDeadline) ? .giveUp : .wait
    }

    /// Retries an int-returning libssh2 call until it stops returning EAGAIN,
    /// the owner cancels, or a deadline passes.
    ///
    /// - Parameter deadline: overrides the connect-phase ceiling. Nil means
    ///   "whatever `open()` is enforcing", which is nothing once it has
    ///   returned — a live session's own waits are bounded by cancellation.
    @discardableResult
    func retry(until deadline: Date? = nil, _ op: () -> Int32) -> Int32 {
        loop(op, cancellable: true, deadline: deadline ?? connectDeadline)
    }

    /// Retries for a fixed slice of time, ignoring cancellation.
    ///
    /// For teardown, which runs *because* the caller is closing: a cancellable
    /// retry would see `shouldClose` already set and give up on its first
    /// EAGAIN, turning every polite channel close into an abrupt one. Bounded
    /// all the same, so a peer that never acknowledges cannot decide when
    /// teardown ends.
    @discardableResult
    func retryDuringTeardown(within seconds: TimeInterval, _ op: () -> Int32) -> Int32 {
        loop(op, cancellable: false, deadline: Date().addingTimeInterval(seconds))
    }

    private func loop(_ op: () -> Int32, cancellable: Bool, deadline: Date?) -> Int32 {
        while true {
            switch Self.retryStep(rc: op(),
                                  isCancelled: cancellable && isCancelled(),
                                  isPastDeadline: deadline.map { Date() >= $0 } ?? false) {
            case .finished(let rc): return rc
            case .giveUp:           return LIBSSH2_ERROR_TIMEOUT
            case .wait:             waitSocket()
            }
        }
    }

    /// Blocks until the socket is ready in the direction libssh2 is waiting on.
    func waitSocket() {
        guard let session, socket >= 0 else { return }
        var pfd = pollfd(fd: socket, events: 0, revents: 0)
        let directions = libssh2_session_block_directions(session)
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { pfd.events |= Int16(POLLIN) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { pfd.events |= Int16(POLLOUT) }
        if pfd.events == 0 { pfd.events = Int16(POLLIN) }
        _ = poll(&pfd, 1, 200)   // 200 ms cap so close/resize stay responsive
    }

    /// The address this connection is actually talking to, as a numeric string.
    ///
    /// `getpeername` rather than a second `getaddrinfo`: the point is to name
    /// the machine that answered, not to ask DNS the same question twice and
    /// hope for the same answer. Nil once the socket is closed.
    var peerAddress: String? {
        guard socket >= 0 else { return nil }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(socket, $0, &length) == 0
            }
        }
        guard named else { return nil }

        var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard rc == 0 else { return nil }
        return String(cString: text)
    }

    /// libssh2's description of the most recent failure, or a placeholder once
    /// the session is gone.
    var lastError: String {
        guard let session else { return "the SSH session is closed" }
        return libssh2LastError(session)
    }

    // MARK: - Host key

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
        let typeName = Self.hostKeyTypeName(keyType)
        let endpoint = KnownHostsStore.endpoint(host: host.hostname, port: host.port)

        switch knownHosts.status(endpoint: endpoint, keyType: typeName, fingerprint: fingerprint) {
        case .match:
            return nil

        case .unknown:
            // Trust-on-first-use: ask the verifier. An interactive one prompts;
            // the File Provider extension's refuses, because a process with no
            // UI silently pinning whatever answered is not trust-on-first-use,
            // it is trust-on-nobody's-say-so.
            guard hostKeyVerifier.shouldTrust(endpoint: endpoint,
                                              keyType: typeName,
                                              fingerprint: fingerprint) else {
                return SSHError.connectionFailed("host key for \(endpoint) was not trusted")
            }
            return remember(endpoint: endpoint, keyType: typeName, fingerprint: fingerprint)

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
            return remember(endpoint: endpoint, keyType: typeName, fingerprint: fingerprint)
        }
    }

    /// Pins a key the verifier accepted. Refuses the connection rather than
    /// proceeding unpinned: a silent failure here means the next connection
    /// sees this host as new again, with no record of what was trusted.
    private func remember(endpoint: String, keyType: String, fingerprint: String) -> Error? {
        do {
            try knownHosts.remember(endpoint: endpoint, keyType: keyType,
                                    fingerprint: fingerprint)
            return nil
        } catch {
            return SSHError.connectionFailed(
                "couldn't record the host key for \(endpoint): \(error.localizedDescription)")
        }
    }

    static func hostKeyTypeName(_ type: Int32) -> String {
        switch type {
        case LIBSSH2_HOSTKEY_TYPE_RSA:       return "ssh-rsa"
        case LIBSSH2_HOSTKEY_TYPE_DSS:       return "ssh-dss"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return "ecdsa-sha2-nistp256"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return "ecdsa-sha2-nistp384"
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return "ecdsa-sha2-nistp521"
        case LIBSSH2_HOSTKEY_TYPE_ED25519:   return "ssh-ed25519"
        default: return "unknown"
        }
    }

    // MARK: - Authentication

    private func authenticate(_ session: OpaquePointer) -> Error? {
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
                            retry {
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
                KeyAuthFailure.message(code: rc,
                                       libssh2Message: libssh2LastError(session),
                                       hasPassphrase: credential.passphrase?.isEmpty == false,
                                       username: user))
        }

        if let password = credential.password {
            let rc = user.withCString { userPtr -> Int32 in
                password.withCString { passPtr in
                    retry {
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
}
#endif
