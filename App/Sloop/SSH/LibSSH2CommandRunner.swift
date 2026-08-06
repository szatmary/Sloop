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
// ⚠️ Written against the stable libssh2 C API. The connect/handshake/host-key/
// auth path deliberately mirrors `LibSSH2Transport` (kept as a separate copy so
// a typo here can't break the working shell transport); a future refactor can
// extract a shared `SSHSession` helper. Expect a fix-up pass on first build —
// mainly around exact constant/typedef spellings the Swift importer produces.
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
    private let host: SSHHost
    private let credential: Credential
    private let knownHosts: KnownHostsStore
    private let hostKeyVerifier: HostKeyVerifier

    init(host: SSHHost,
         credential: Credential,
         knownHosts: KnownHostsStore,
         hostKeyVerifier: HostKeyVerifier = AutoAcceptHostKeyVerifier()) {
        self.host = host
        self.credential = credential
        self.knownHosts = knownHosts
        self.hostKeyVerifier = hostKeyVerifier
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
        guard libssh2_init(0) == 0 else {
            return .failure(SSHError.connectionFailed("libssh2_init failed"))
        }
        defer { libssh2_exit() }

        let sock: Int32
        do {
            sock = try openSocket(host: host.hostname, port: host.port)
        } catch {
            return .failure(error)
        }
        defer { Darwin.close(sock) }

        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            return .failure(SSHError.connectionFailed("session_init failed"))
        }
        defer {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(session)
        }
        libssh2_session_set_blocking(session, 0)

        let rc = retry(session, sock) { libssh2_session_handshake(session, sock) }
        guard rc == 0 else { return .failure(SSHError.connectionFailed("handshake rc=\(rc)")) }

        if let error = verifyHostKey(session) { return .failure(error) }
        if let error = authenticate(session, sock) { return .failure(error) }

        // Open an exec channel — no PTY, no interactive shell.
        guard let channel = openExecChannel(session, sock) else {
            return .failure(SSHError.channelFailure("could not open exec channel"))
        }
        defer {
            _ = retry(session, sock) { libssh2_channel_close(channel) }
            libssh2_channel_free(channel)
        }

        let request = "exec"
        let startRC = request.withCString { reqPtr -> Int32 in
            command.withCString { cmdPtr in
                retry(session, sock) {
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
                waitSocket(sock, session)
                continue
            }
            break                                  // both streams at EOF (0) or error
        }

        // Ask the server to close, then read the exit status.
        _ = retry(session, sock) { libssh2_channel_close(channel) }
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

    private func openExecChannel(_ session: OpaquePointer, _ sock: Int32) -> OpaquePointer? {
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
                    waitSocket(sock, session); continue
                }
                return nil
            }
        }
        return channel
    }

    // MARK: - Host key + auth (mirrors LibSSH2Transport)

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
            guard hostKeyVerifier.shouldTrust(endpoint: endpoint,
                                              keyType: typeName,
                                              fingerprint: fingerprint) else {
                return SSHError.connectionFailed("host key for \(endpoint) was not trusted")
            }
            knownHosts.remember(endpoint: endpoint, keyType: typeName, fingerprint: fingerprint)
            return nil
        case .mismatch:
            return SSHError.connectionFailed("host key changed for \(endpoint) — refusing to connect")
        }
    }

    private func authenticate(_ session: OpaquePointer, _ sock: Int32) -> Error? {
        let user = host.username

        if let key = credential.privateKeyPEM {
            let rc = user.withCString { userPtr -> Int32 in
                key.withCString { keyPtr in
                    (credential.passphrase ?? "").withCString { passPtr in
                        retry(session, sock) {
                            libssh2_userauth_publickey_frommemory(
                                session, userPtr, user.utf8.count,
                                nil, 0,
                                keyPtr, key.utf8.count,
                                passPtr)
                        }
                    }
                }
            }
            return rc == 0 ? nil : SSHError.authenticationFailed
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
            return rc == 0 ? nil : SSHError.authenticationFailed
        }

        return SSHError.authenticationFailed
    }

    // MARK: - libssh2 non-blocking helpers (mirror LibSSH2Transport)

    private func retry(_ session: OpaquePointer, _ sock: Int32, _ op: () -> Int32) -> Int32 {
        while true {
            let rc = op()
            if rc == LIBSSH2_ERROR_EAGAIN { waitSocket(sock, session); continue }
            return rc
        }
    }

    private func waitSocket(_ sock: Int32, _ session: OpaquePointer) {
        var pfd = pollfd(fd: sock, events: 0, revents: 0)
        let directions = libssh2_session_block_directions(session)
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { pfd.events |= Int16(POLLIN) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { pfd.events |= Int16(POLLOUT) }
        if pfd.events == 0 { pfd.events = Int16(POLLIN) }
        _ = poll(&pfd, 1, 200)
    }

    private func hostKeyTypeName(_ type: Int32) -> String {
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

    private func openSocket(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let addrs = result else {
            throw SSHError.connectionFailed("cannot resolve \(host)")
        }
        defer { freeaddrinfo(addrs) }

        var info: UnsafeMutablePointer<addrinfo>? = addrs
        while let candidate = info {
            let fd = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
            if fd >= 0 {
                if connect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                    return fd
                }
                Darwin.close(fd)
            }
            info = candidate.pointee.ai_next
        }
        throw SSHError.connectionFailed("cannot connect to \(host):\(port)")
    }
}
#endif
