// Tests/SloopKitTests/CloudflareAccessDialerTests.swift
import XCTest
@testable import SloopKit
#if canImport(Network)
import Network

final class CloudflareAccessDialerTests: XCTestCase {

    // MARK: WebSocket echo server (data path)

    private final class WSEchoServer {
        let listener: NWListener
        private(set) var port: UInt16 = 0

        init() throws {
            let params = NWParameters.tcp
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
        }

        func start() {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                self.echoLoop(conn)
            }
            listener.start(queue: .global())
            ready.wait()
            port = listener.port!.rawValue
        }

        private func echoLoop(_ conn: NWConnection) {
            conn.receiveMessage { data, context, _, error in
                guard let data, error == nil else { return }
                let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                let ctx = NWConnection.ContentContext(identifier: "echo",
                                                      metadata: [meta])
                conn.send(content: data, contentContext: ctx,
                          completion: .contentProcessed { _ in })
                self.echoLoop(conn)
            }
        }
    }

    func testEchoesBytesThroughReturnedFD() throws {
        let server = try WSEchoServer()
        server.start()
        defer { server.listener.cancel() }

        let dialer = CloudflareAccessDialer(
            url: URL(string: "ws://127.0.0.1:\(server.port)")!,
            hostname: "ssh.example.com", token: "test-token")
        let fd = try dialer.dial()
        defer { close(fd) }

        let sent: [UInt8] = Array("SSH-2.0-Sloop\r\n".utf8)
        _ = sent.withUnsafeBytes { write(fd, $0.baseAddress, sent.count) }
        var buf = [UInt8](repeating: 0, count: 64)
        var got: [UInt8] = []
        while got.count < sent.count {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            got.append(contentsOf: buf[0..<n])
        }
        XCTAssertEqual(got, sent)
    }

    // MARK: Raw TCP server (header + error mapping)

    /// Accepts one TCP connection, captures what the client sent, replies with
    /// a canned HTTP response, closes.
    private final class CannedHTTPServer {
        let listener: NWListener
        private(set) var port: UInt16 = 0
        private(set) var request: String = ""
        private let response: String
        let sawRequest = XCTestExpectation(description: "request captured")

        init(response: String) throws {
            self.response = response
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, _, _ in
                    self.request = String(decoding: data ?? Data(), as: UTF8.self)
                    self.sawRequest.fulfill()
                    conn.send(content: Data(self.response.utf8),
                              completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                }
            }
            listener.start(queue: .global())
            ready.wait()
            port = listener.port!.rawValue
        }
    }

    func testSendsTokenHeaderAndMapsForbiddenToAccessDenied() throws {
        let server = try CannedHTTPServer(
            response: "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        server.start()
        defer { server.listener.cancel() }

        let dialer = CloudflareAccessDialer(
            url: URL(string: "ws://127.0.0.1:\(server.port)")!,
            hostname: "ssh.example.com", token: "sekrit-token")
        XCTAssertThrowsError(try dialer.dial()) { error in
            guard case SSHError.accessDenied(let host) = error else {
                return XCTFail("expected accessDenied, got \(error)")
            }
            XCTAssertEqual(host, "ssh.example.com")
        }
        wait(for: [server.sawRequest], timeout: 5)
        // Lowercase only the header *name* for matching (header names are
        // case-insensitive; values are not) — a mixed-case JWT compared
        // after lowercasing the whole request would silently pass even if
        // the value got mangled.
        let headerLine = server.request
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("cf-access-token:") }
        guard let headerLine else {
            return XCTFail("upgrade request must carry the cf-access-token header; got:\n\(server.request)")
        }
        let value = String(headerLine.drop(while: { $0 != ":" }).dropFirst())
            .trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(value, "sekrit-token",
                      "token header value must be sent verbatim (case-sensitive); got:\n\(server.request)")
    }

    func testMapsRedirectToAccessLoginRequired() throws {
        // Stand-in for the IdP the Access redirect would send a *following*
        // client to. Asserting this listener is never contacted is what
        // actually proves the redirect wasn't followed — checking only for
        // `accessLoginRequired` doesn't: that error comes from the original
        // 302's status code either way, so it would just as happily "pass"
        // with the redirect-refusal delegate method deleted entirely, and
        // on a network with wildcard DNS a `Location` pointing at a bogus
        // hostname could make a real outbound connection instead of failing
        // to resolve.
        let canary = try NWListener(using: .tcp, on: .any)
        let canaryContacted = XCTestExpectation(description: "canary must not be contacted")
        canaryContacted.isInverted = true
        canary.newConnectionHandler = { conn in
            conn.cancel()
            canaryContacted.fulfill()
        }
        let canaryReady = DispatchSemaphore(value: 0)
        canary.stateUpdateHandler = { if case .ready = $0 { canaryReady.signal() } }
        canary.start(queue: .global())
        canaryReady.wait()
        let canaryPort = canary.port!.rawValue
        defer { canary.cancel() }

        let server = try CannedHTTPServer(
            response: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(canaryPort)/\r\nContent-Length: 0\r\n\r\n")
        server.start()
        defer { server.listener.cancel() }

        let dialer = CloudflareAccessDialer(
            url: URL(string: "ws://127.0.0.1:\(server.port)")!,
            hostname: "ssh.example.com", token: "stale")
        XCTAssertThrowsError(try dialer.dial()) { error in
            guard case SSHError.accessLoginRequired = error else {
                return XCTFail("expected accessLoginRequired, got \(error)")
            }
        }
        wait(for: [canaryContacted], timeout: 1)
    }
}
#endif
