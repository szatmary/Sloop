// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

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

    /// Serial queue that inbound WebSocket frames are drained through
    /// instead of URLSession's delegate queue — see `deliverInbound`'s doc
    /// comment for why that distinction is load-bearing, not cosmetic.
    private let inboundQueue = DispatchQueue(label: "org.szatmary.sloop.cfaccessdialer.inbound")

    /// - Parameters:
    ///   - url: `wss://<hostname>` in production; tests inject `ws://127.0.0.1:…`.
    ///   - hostname: the Access app hostname, used in error messages.
    ///   - token: the raw Access JWT to present.
    ///   - openTimeout: bounds both the initial WebSocket handshake and (see
    ///     `onOutbound`) how long a single outbound frame's send is allowed
    ///     to sit unacknowledged before the dialer gives up and tears down.
    ///     One knob for both is deliberate: both are "how long is this
    ///     network allowed to be silent before we call it dead."
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
        relay.onOutbound = { [weak self, weak task] data in
            guard let self, let task else { return }
            // Block the pump thread until the send actually completes. This
            // *is* the relay's backpressure mechanism applied to the
            // WebSocket leg: without it, a fast local writer over a slow
            // tunnel queues sends in URLSession without bound. A send
            // failure fails the task; the in-flight `task.receive()` call
            // then resolves `.failure`, and `receiveLoop` calls
            // `relay.finishInbound()` so libssh2 sees a clean EOF — the
            // failure reason itself is not surfaced anywhere else.
            //
            // Bounded by `openTimeout`: this thread never gets back to
            // `read()` while parked here, so nothing else would notice a
            // send whose completion never fires and tear things down —
            // this is what has to do it instead. (This is also what makes
            // "URLSession always invokes a completion exactly once" a
            // non-load-bearing assumption: even if that contract were ever
            // violated, this can't park a thread forever.) See
            // `deliverInbound` for why this wait is safe from the deadlock
            // a naive version of it had: with inbound delivery off
            // URLSession's delegate queue, this send's completion can no
            // longer be stuck behind a blocked `receive` callback on that
            // same serial queue.
            let sent = DispatchSemaphore(value: 0)
            task.send(.data(data)) { _ in sent.signal() }
            guard sent.wait(timeout: .now() + self.openTimeout) == .success else {
                self.tearDown()
                return
            }
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
                self?.deliverInbound(data, task, relay)
            case .success(.string(let text)):
                self?.deliverInbound(Data(text.utf8), task, relay)
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

    /// Writing a received frame into the relay (`relay.receive`) blocks
    /// until libssh2 drains `localFD` — that's the relay's whole
    /// backpressure design, and it's correct at the fd level. But
    /// `task.receive`'s completion handler fires on URLSession's *serial*
    /// delegate queue — the very same queue that delivers `onOutbound`'s
    /// `task.send` completions. Doing the blocking write inline, right
    /// there on that queue (as an earlier version of this method did), can
    /// park it — starving every completion queued behind it, including the
    /// send completion `onOutbound` is blocked waiting for. With both
    /// directions active at once that's a guaranteed deadlock: the pump
    /// blocked on a send completion that's stuck behind a blocked receive
    /// callback, which is itself stuck because the pump — the one thing
    /// that could let `remoteFD` drain — isn't running to do so.
    ///
    /// So the write, and the re-arm (calling `task.receive()` again) that
    /// only happens once it returns, are pushed onto `inboundQueue`
    /// instead. That frees the delegate queue immediately, so send
    /// completions always get to run. `inboundQueue` being serial, and only
    /// re-arming after the current write finishes, keeps both properties
    /// `relay.receive` was already providing: in-order delivery, and
    /// backpressure — at most one frame is ever in flight between the
    /// network and `remoteFD`.
    private func deliverInbound(_ data: Data, _ task: URLSessionWebSocketTask, _ relay: SocketPairRelay) {
        inboundQueue.async { [weak self] in
            relay.receive(data)
            self?.receiveLoop(task, relay)
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
