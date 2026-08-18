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

    /// libssh2's global init, run exactly once per process.
    ///
    /// It used to be per-connection, paired with a `defer { libssh2_exit() }`.
    /// That is safe only while one session exists at a time, which stopped
    /// being true the moment the terminal grew tabs — closing one tab called
    /// `libssh2_exit()` underneath every other live session — and is
    /// emphatically untrue now that an SFTP pool keeps sessions open per host.
    /// libssh2 does not reference-count these, so the fix is to initialize once
    /// and never tear down; the library's own documentation treats `exit` as an
    /// end-of-program call.
    private static let initializeOnce: Int32 = libssh2_init(0)

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
        guard Self.initializeOnce == 0 else {
            throw SSHError.connectionFailed("libssh2_init failed")
        }

        socket = try dialer.dial()

        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            close()
            throw SSHError.connectionFailed("session_init failed")
        }
        self.session = session
        libssh2_session_set_blocking(session, 0)

        do {
            let rc = retry { libssh2_session_handshake(session, self.socket) }
            guard rc == 0 else {
                throw SSHError.connectionFailed("handshake rc=\(rc)")
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

    /// Retries an int-returning libssh2 call until it stops returning EAGAIN.
    @discardableResult
    func retry(_ op: () -> Int32) -> Int32 {
        while true {
            let rc = op()
            if rc == LIBSSH2_ERROR_EAGAIN { waitSocket(); continue }
            return rc
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
                "server rejected the private key for '\(user)' — \(libssh2LastError(session))")
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
