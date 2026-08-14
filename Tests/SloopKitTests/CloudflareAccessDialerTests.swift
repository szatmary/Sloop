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
        XCTAssertTrue(server.request.lowercased().contains("cf-access-token: sekrit-token"),
                      "upgrade request must carry the token header; got:\n\(server.request)")
    }

    func testMapsRedirectToAccessLoginRequired() throws {
        let server = try CannedHTTPServer(
            response: "HTTP/1.1 302 Found\r\nLocation: https://login.example\r\nContent-Length: 0\r\n\r\n")
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
    }
}
#endif
