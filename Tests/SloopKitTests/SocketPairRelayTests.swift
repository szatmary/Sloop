// Tests/SloopKitTests/SocketPairRelayTests.swift
import XCTest
@testable import SloopKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class SocketPairRelayTests: XCTestCase {

    func testOutboundBytesReachCallback() throws {
        let relay = try SocketPairRelay()
        var collected = Data()
        let got = expectation(description: "outbound")
        got.assertForOverFulfill = false
        relay.onOutbound = { data in
            collected.append(data)
            if collected.count >= 5 { got.fulfill() }
        }
        relay.start()
        let bytes: [UInt8] = [10, 20, 30, 40, 50]
        _ = bytes.withUnsafeBytes { write(relay.localFD, $0.baseAddress, bytes.count) }
        wait(for: [got], timeout: 5)
        XCTAssertEqual([UInt8](collected.prefix(5)), bytes)
        close(relay.localFD)
        relay.shutdown()
    }

    func testReceiveIsReadableOnLocalFD() throws {
        let relay = try SocketPairRelay()
        relay.start()
        relay.receive(Data([7, 8, 9]))
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(relay.localFD, &buf, buf.count)
        XCTAssertEqual(Array(buf[0..<n]), [7, 8, 9])
        close(relay.localFD)
        relay.shutdown()
    }

    func testFinishInboundGivesLocalReaderEOF() throws {
        let relay = try SocketPairRelay()
        relay.start()
        relay.receive(Data([1]))
        relay.finishInbound()
        var buf = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(read(relay.localFD, &buf, buf.count), 1)   // the byte
        XCTAssertEqual(read(relay.localFD, &buf, buf.count), 0)   // then EOF
        close(relay.localFD)
        relay.shutdown()
    }

    func testLocalCloseFiresCallbackAndLaterReceiveIsSafe() throws {
        let relay = try SocketPairRelay()
        let closed = expectation(description: "local closed")
        relay.onLocalClosed = { closed.fulfill() }
        relay.start()
        close(relay.localFD)
        wait(for: [closed], timeout: 5)
        relay.receive(Data([1, 2, 3]))   // must not crash (EPIPE, no SIGPIPE)
        relay.shutdown()
    }

    /// 1 MB through both directions exercises partial writes + backpressure
    /// (socketpair buffers are only a few KB).
    func testLargeTransfer() throws {
        let relay = try SocketPairRelay()
        let payload = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0) })
        var echoed = Data()
        let done = expectation(description: "echoed all")
        relay.onOutbound = { data in
            echoed.append(data)
            if echoed.count == payload.count { done.fulfill() }
        }
        relay.start()
        // Reader thread drains localFD so receive() can make progress, and
        // echoes everything back out through the fd.
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 32 * 1024)
            var received = 0
            while received < payload.count {
                let n = read(relay.localFD, &buf, buf.count)
                guard n > 0 else { return }
                received += n
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes {
                        write(relay.localFD, $0.baseAddress!.advanced(by: off), n - off)
                    }
                    guard w > 0 else { return }
                    off += w
                }
            }
        }
        relay.receive(payload)
        wait(for: [done], timeout: 20)
        XCTAssertEqual(echoed, payload)
        close(relay.localFD)
        relay.shutdown()
    }

    /// Exercises the teardown race `shutdown()` has to be safe against:
    /// another thread hammering `receive()` (blocking writes against the
    /// small kernel buffer) while `shutdown()` runs concurrently on a third
    /// thread. `shutdown()` must poison the fd before freeing its number,
    /// so a racing `receive()` can never be redirected onto an unrelated fd
    /// the OS reused in between — and deliberate teardown must never look
    /// like the local side going away, so `onLocalClosed` must not fire.
    func testShutdownDuringConcurrentReceiveIsSafeAndSuppressesLocalClosed() throws {
        let relay = try SocketPairRelay()

        let notClosed = expectation(description: "onLocalClosed must not fire on deliberate shutdown")
        notClosed.isInverted = true
        relay.onLocalClosed = { notClosed.fulfill() }
        relay.start()

        // Drains localFD concurrently so receive()'s blocking writes can
        // make progress instead of stalling the race under test.
        let readerDone = expectation(description: "reader drained until closed")
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            while read(relay.localFD, &buf, buf.count) > 0 {}
            readerDone.fulfill()
        }

        // Hammers receive() from another thread while shutdown() runs
        // concurrently on a third — the exact race finding 1 closes.
        let receiverDone = expectation(description: "receiver finished without crashing")
        let payload = Data(repeating: 0x42, count: 4096)
        Thread.detachNewThread {
            for _ in 0..<500 {
                relay.receive(payload)
            }
            receiverDone.fulfill()
        }

        let shutdownDone = expectation(description: "shutdown returned")
        Thread.detachNewThread {
            relay.shutdown()
            shutdownDone.fulfill()
        }

        wait(for: [shutdownDone, receiverDone], timeout: 10)
        close(relay.localFD)
        wait(for: [readerDone], timeout: 5)
        // Final bounded grace period: confirm no late/delayed onLocalClosed.
        wait(for: [notClosed], timeout: 1)
    }
}
