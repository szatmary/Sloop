import XCTest
@testable import SloopKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class DialerTests: XCTestCase {

    /// Bind a TCP listener on 127.0.0.1 on an OS-assigned port.
    private func makeListener() -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return (fd, Int(UInt16(bigEndian: out.sin_port)))
    }

    func testDialConnectsAndCarriesBytes() throws {
        let (listenFD, port) = makeListener()
        defer { close(listenFD) }

        // Echo one round on the accepted connection, then close it.
        let served = expectation(description: "served")
        Thread.detachNewThread {
            let conn = accept(listenFD, nil, nil)
            var buf = [UInt8](repeating: 0, count: 16)
            let n = read(conn, &buf, buf.count)
            _ = buf.withUnsafeBytes { write(conn, $0.baseAddress, n) }
            close(conn)
            served.fulfill()
        }

        let fd = try TCPDialer(host: "127.0.0.1", port: port).dial()
        defer { close(fd) }
        let hello: [UInt8] = [1, 2, 3, 4, 5]
        _ = hello.withUnsafeBytes { write(fd, $0.baseAddress, hello.count) }
        var back = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &back, back.count)
        XCTAssertEqual(Array(back[0..<n]), hello)
        wait(for: [served], timeout: 5)
    }

    func testDialThrowsWhenNothingListens() {
        // Grab a port the OS just released so nothing is listening on it.
        let (fd, port) = makeListener()
        close(fd)
        XCTAssertThrowsError(try TCPDialer(host: "127.0.0.1", port: port).dial()) { error in
            guard case SSHError.connectionFailed = error else {
                return XCTFail("expected SSHError.connectionFailed, got \(error)")
            }
        }
    }

    func testDialThrowsOnUnresolvableHost() {
        XCTAssertThrowsError(
            try TCPDialer(host: "sloop-invalid.invalid", port: 22).dial())
    }
}
