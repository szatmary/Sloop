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
        if let error = openError {
            defer { tearDown() }
            throw mapOpenFailure(error)
        }

        let relay = try SocketPairRelay()
        self.relay = relay
        relay.onOutbound = { [weak task] data in
            task?.send(.data(data)) { _ in }   // send failures surface via receive
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
                relay.finishInbound()   // remote closed; libssh2 sees EOF
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
        opened.signal()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        if let error {
            openError = error
            opened.signal()   // no-op if already open; then receive() reports it
        }
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
