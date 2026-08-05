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
    var onClose: ((Error?) -> Void)?

    private let host: SSHHost
    private let credential: Credential
    private let knownHosts: KnownHostsStore

    private let lock = NSLock()
    private var outbound: [UInt8] = []
    private var pendingResize: (cols: Int, rows: Int)?
    private var shouldClose = false

    init(host: SSHHost, credential: Credential, knownHosts: KnownHostsStore) {
        self.host = host
        self.credential = credential
        self.knownHosts = knownHosts
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
            sock = try openSocket(host: host.hostname, port: host.port)
        } catch {
            return finish(error)
        }
        defer { Darwin.close(sock) }

        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            return finish(SSHError.connectionFailed("session_init failed"))
        }
        defer {
            libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "")
            libssh2_session_free(session)
        }
        libssh2_session_set_blocking(session, 0)

        // Handshake
        var rc = retry(session, sock) { libssh2_session_handshake(session, sock) }
        guard rc == 0 else { return finish(SSHError.connectionFailed("handshake rc=\(rc)")) }

        // Host-key verification (trust-on-first-use)
        if let error = verifyHostKey(session) { return finish(error) }

        // Authenticate
        if let error = authenticate(session, sock) { return finish(error) }

        // Open a shell channel with a PTY
        guard let channel = openShell(session, sock) else {
            return finish(SSHError.channelFailure("could not open shell"))
        }
        defer {
            _ = retry(session, sock) { libssh2_channel_close(channel) }
            libssh2_channel_free(channel)
        }

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
            // TODO(ssh): surface a trust-on-first-use prompt through the UI.
            // For now we record and proceed.
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

    private func openShell(_ session: OpaquePointer, _ sock: Int32) -> OpaquePointer? {
        var channel: OpaquePointer?
        while channel == nil {
            channel = "session".withCString {
                libssh2_channel_open_ex(session, $0, UInt32(7),
                                        UInt32(LIBSSH2_CHANNEL_WINDOW_DEFAULT),
                                        UInt32(LIBSSH2_CHANNEL_PACKET_DEFAULT), nil, 0)
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
        var rc = term.withCString { termPtr in
            retry(session, sock) {
                libssh2_channel_request_pty_ex(channel, termPtr, UInt32(term.utf8.count),
                                               nil, 0, 80, 24, 0, 0)
            }
        }
        guard rc == 0 else { return nil }

        rc = "shell".withCString { shellPtr in
            retry(session, sock) {
                libssh2_channel_process_startup(channel, shellPtr, 5, nil, 0)
            }
        }
        return rc == 0 ? channel : nil
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
                let n = buffer.withUnsafeMutableBytes {
                    libssh2_channel_read_ex(channel, 0, $0.bindMemory(to: CChar.self).baseAddress, buffer.count)
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

    /// Resolve `host:port` and return a connected blocking TCP socket.
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
