// Sources/SloopKit/Cloudflare/CloudflareAccessDialer.swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Dials an SSH host behind Cloudflare Tunnel the way `cloudflared access ssh`
/// does: a WebSocket to the Access-protected hostname, authenticated by the
/// Access JWT in the `cf-access-token` header, with binary frames carrying the
/// raw SSH byte stream. A `SocketPairRelay` turns that into the fd libssh2
/// expects.
///
/// Single-use, like every `Dialer`. The instance must outlive the returned fd
/// — it owns the WebSocket task and the relay pumping it.
public final class CloudflareAccessDialer: NSObject, Dialer {
    private let url: URL
    private let hostname: String
    private let token: String
    private let openTimeout: TimeInterval

    private var relay: SocketPairRelay?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let opened = DispatchSemaphore(value: 0)

    /// Guards `didOpen`/`openError` together. `didOpenWithProtocol` and
    /// `didCompleteWithError` both run on URLSession's serial delegate
    /// queue, so they can't race *each other* — but without this lock they
    /// can race `dial()`'s post-`wait()` read, which runs on a different
    /// thread with no other synchronizing operation between the write and
    /// the read. Also lets `didCompleteWithError` tell a pre-open failure
    /// (the handshake itself failed — `dial()` is still blocked in
    /// `opened.wait()`) from a post-open one (the session was open and later
    /// dropped — `dial()` has already returned a live fd, and the pending
    /// `task.receive()` call surfaces this on its own; see `receiveLoop`).
    private let handshakeLock = NSLock()
    private var didOpen = false
    private var openError: Error?

    /// - Parameters:
    ///   - url: `wss://<hostname>` in production; tests inject `ws://127.0.0.1:…`.
    ///   - hostname: the Access app hostname, used in error messages.
    ///   - token: the raw Access JWT to present.
    public init(url: URL, hostname: String, token: String,
                openTimeout: TimeInterval = 20) {
        self.url = url
        self.hostname = hostname
        self.token = token
        self.openTimeout = openTimeout
    }

    public func dial() throws -> Int32 {
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "cf-access-token")

        let session = URLSession(configuration: .ephemeral,
                                 delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        guard opened.wait(timeout: .now() + openTimeout) == .success else {
            tearDown()
            throw SSHError.connectionFailed("timed out connecting to \(hostname)")
        }
        handshakeLock.lock()
        let handshakeFailure = openError
        handshakeLock.unlock()
        if let handshakeFailure {
            defer { tearDown() }
            throw mapOpenFailure(handshakeFailure)
        }

        let relay: SocketPairRelay
        do {
            relay = try SocketPairRelay()
        } catch {
            // The WebSocket is already open at this point; without this the
            // task/session (and, via URLSession's retain of its delegate,
            // this dialer) would leak forever instead of being cancelled.
            tearDown()
            throw error
        }
        self.relay = relay
        relay.onOutbound = { [weak task] data in
            guard let task else { return }
            // Block the pump thread until the send actually completes. This
            // *is* the relay's backpressure mechanism applied to the
            // WebSocket leg: without it, a fast local writer over a slow
            // tunnel queues sends in URLSession without bound. A send
            // failure fails the task; the in-flight `task.receive()` call
            // then resolves `.failure`, and `receiveLoop` calls
            // `relay.finishInbound()` so libssh2 sees a clean EOF — the
            // failure reason itself is not surfaced anywhere else.
            let sent = DispatchSemaphore(value: 0)
            task.send(.data(data)) { _ in sent.signal() }
            sent.wait()
        }
        relay.onLocalClosed = { [weak self] in self?.tearDown() }
        relay.start()
        receiveLoop(task, relay)
        return relay.localFD
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, _ relay: SocketPairRelay) {
        task.receive { [weak self] result in
            switch result {
            case .success(.data(let data)):
                relay.receive(data)
                self?.receiveLoop(task, relay)
            case .success(.string(let text)):
                relay.receive(Data(text.utf8))
                self?.receiveLoop(task, relay)
            case .success:
                self?.receiveLoop(task, relay)
            case .failure:
                // Covers both a clean remote close and a transport failure
                // (dropped connection, cancelled task, etc.) — `receive`
                // doesn't distinguish them, so neither do we. Either way,
                // finishing the inbound side is the correct fd-level
                // behavior: libssh2 sees a normal EOF. The specific failure
                // reason (if any) is not surfaced to the caller.
                relay.finishInbound()
            }
        }
    }

    /// Read the HTTP status behind a failed upgrade and name the real problem.
    private func mapOpenFailure(_ error: Error) -> Error {
        guard let http = task?.response as? HTTPURLResponse else {
            return SSHError.connectionFailed(
                "\(hostname): \(error.localizedDescription)")
        }
        switch http.statusCode {
        case 300...399, 401:                       // Access bounce to the IdP
            return SSHError.accessLoginRequired(host: hostname)
        case 403:
            return SSHError.accessDenied(host: hostname)
        default:
            return SSHError.connectionFailed(
                "\(hostname): HTTP \(http.statusCode) during WebSocket upgrade")
        }
    }

    private func tearDown() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
        relay?.shutdown()
    }
}

extension CloudflareAccessDialer: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        handshakeLock.lock()
        didOpen = true
        handshakeLock.unlock()
        opened.signal()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let error else { return }
        handshakeLock.lock()
        let isPreOpenFailure = !didOpen
        if isPreOpenFailure { openError = error }
        handshakeLock.unlock()
        guard isPreOpenFailure else {
            // The handshake already succeeded and `dial()` has returned a
            // live fd; this is a post-open transport failure. Don't touch
            // `openError` (which `dial()` already read) or route it through
            // `mapOpenFailure` (which would read `task.response` as the
            // *original* 101 upgrade response and produce a nonsense "HTTP
            // 101" message). `receiveLoop`'s in-flight `task.receive()`
            // call surfaces this as `.failure` on its own.
            return
        }
        opened.signal()   // unblocks dial()'s handshake wait with the failure
    }

    /// Don't follow the Access 302 to the IdP — surface it so the app can run
    /// the browser login instead.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
