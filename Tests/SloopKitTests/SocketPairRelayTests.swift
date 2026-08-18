// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

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

    /// The natural, expected way for an owner to wire this relay is
    /// `onLocalClosed = { relay.shutdown() }` — exactly what Task 7's
    /// `CloudflareAccessDialer` does via `tearDown()`. `onLocalClosed` fires
    /// *on the pump thread itself*, from inside `pumpOutbound()`, before its
    /// `defer` marks the pump as exited. A `shutdown()` that unconditionally
    /// tries to join the pump thread would therefore have the pump thread
    /// wait for itself to finish: a permanent deadlock, on the guaranteed
    /// end-of-session path (every `Dialer` contract closure of `localFD`
    /// goes through here). This test reproduces exactly that call shape and
    /// bounds the wait so a regression shows up as a timed-out expectation
    /// instead of a hung test run.
    func testShutdownFromOnLocalClosedDoesNotDeadlock() throws {
        let relay = try SocketPairRelay()
        let localFD = relay.localFD

        let shutdownReturned = expectation(description: "reentrant shutdown() returned")
        relay.onLocalClosed = { [weak relay] in
            relay?.shutdown()
            shutdownReturned.fulfill()
        }
        relay.start()

        close(localFD)   // simulates libssh2 closing its end, as a real caller would

        wait(for: [shutdownReturned], timeout: 5)

        // Teardown genuinely finished — not just "returned early without
        // doing anything": `shutdown()`'s own idempotency guard makes even
        // a no-op call return promptly, so a second `shutdown()` call
        // wouldn't prove anything either way. `remoteFDClosed` only flips
        // true at the point `close(remoteFD)` actually runs, at the very
        // end of `shutdown()`, so asserting on it is what actually shows
        // teardown ran to completion rather than merely returning.
        XCTAssertTrue(relay.remoteFDClosed)
    }

    /// Round-3 finding: `onOutbound` is a reentrant `shutdown()` call site
    /// too (`CloudflareAccessDialer` tears down from inside it when a send
    /// times out), but unlike `onLocalClosed` — which always returns right
    /// after firing — `onOutbound` fires *mid-loop*, with another
    /// `read(remoteFD, …)` waiting immediately afterward. Before the fix,
    /// that reentrant `shutdown()` would close `remoteFD` (the pump-thread
    /// branch skips joining, since "the pump is on its way out" was the
    /// premise for that skip) and then the loop would immediately read the
    /// freed fd number again — one the OS is now free to have handed to an
    /// unrelated resource. Whether that manifests as forwarding a stranger's
    /// bytes into the SSH stream or hanging forever depends on what else in
    /// the process reuses that exact fd number at that exact instant, which
    /// is not something a reliable test can depend on — so this checks the
    /// two things that *are* deterministic: the pump thread actually exits
    /// promptly, and it never attempts that second `read()` at all.
    /// `outboundReadCount` counts syscall attempts, not results, so it does
    /// not matter what a stray second read would have returned.
    func testOnOutboundShutdownStopsThePumpFromReadingAgain() throws {
        let relay = try SocketPairRelay()
        relay.onOutbound = { [weak relay] _ in
            relay?.shutdown()
        }
        relay.start()

        let chunk: [UInt8] = [1, 2, 3]
        _ = chunk.withUnsafeBytes { write(relay.localFD, $0.baseAddress, chunk.count) }

        XCTAssertTrue(relay.waitUntilPumpExits(timeout: 5),
                      "pump thread did not exit promptly after a reentrant shutdown() from onOutbound")
        XCTAssertEqual(relay.outboundReadCount, 1,
                      "pump must not read(remoteFD, …) again once onOutbound has torn the relay down " +
                      "— a second attempt would race a freed, recyclable fd number")

        close(relay.localFD)
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
        // Join the drain thread *before* closing `localFD`, not after.
        // `shutdown()` having returned means it ran all the way through
        // `close(remoteFD)`, and closing the peer is what gives this thread
        // its EOF — reliably (measured: 0 misses in 30,000 runs), unlike
        // `shutdown()`'s own wakeup, which is not reliable at all and is what
        // `testPumpNeverParksInsideRead` exists to keep the relay off. Closing
        // `localFD` first, as this used to, meant closing an fd another
        // thread could still be parked in `read()` on: a race the test has
        // no reason to run, and one that on a bad interleaving strands that
        // thread (a `close()` does not unpark a reader already inside
        // `read()` on the fd being closed) and fails the `readerDone` wait
        // for reasons unrelated to anything under test.
        wait(for: [readerDone], timeout: 5)
        close(relay.localFD)
        // Final bounded grace period: confirm no late/delayed onLocalClosed.
        wait(for: [notClosed], timeout: 1)
    }

    /// Round-4 finding, and the load-bearing property of the fix for it.
    ///
    /// `shutdown()` must get the pump out of its wait on `remoteFD` before it
    /// may free that fd's number, and its join loop has no deadline — so a
    /// wakeup that is merely *usually* delivered is a hang, not a delay. On
    /// Darwin that is exactly what a blocked `read()` gives you:
    /// `shutdown(fd, SHUT_RDWR)` returning 0 does not reliably unpark a
    /// `read(fd)` another thread is already inside. Measured on macOS 26.5
    /// with a minimal C repro (one thread parked in `read()` on one end of an
    /// `AF_UNIX` `socketpair`, another calling `shutdown(SHUT_RDWR)` on that
    /// same end): 24 permanent hangs in 5,000 runs, ~0.5%, with `shutdown()`
    /// reporting success every time. A second `shutdown()` does not help
    /// (`ENOTCONN`); only closing the peer fd frees the reader, which is
    /// precisely what teardown may not do yet. That is what
    /// `testShutdownDuringConcurrentReceiveIsSafeAndSuppressesLocalClosed`
    /// had been failing on about 1 run in 100 — not a flake, a teardown-path
    /// hang. `poll()` on the same fd *is* reliably woken by that same
    /// `shutdown()` (0 hangs in 50,000 runs), so the pump now waits there.
    ///
    /// Testing that by racing teardown is a losing proposition — the window
    /// is under a microsecond wide, so even a 4,000-iteration stress loop
    /// reproduced it in only about 2 runs in 5 (that version was written,
    /// measured, and dropped in favour of this one). So assert the property
    /// instead of the symptom: with nothing readable, the pump must be
    /// waiting *outside* `read()`. `outboundReadCount` counts reads at the
    /// point they are issued, so a pump parked inside one has already been
    /// counted — which makes "did it park in `read()`?" directly observable
    /// rather than something to be inferred from a race.
    func testPumpNeverParksInsideRead() throws {
        let relay = try SocketPairRelay()
        let delivered = expectation(description: "first chunk delivered")
        delivered.assertForOverFulfill = false
        relay.onOutbound = { _ in delivered.fulfill() }
        relay.start()

        // One byte through, so the pump is known to be past start-up and back
        // around its loop — without this the count could be 0 simply because
        // the pump thread hasn't run yet, and the test would pass vacuously.
        let chunk: [UInt8] = [7]
        _ = chunk.withUnsafeBytes { write(relay.localFD, $0.baseAddress, chunk.count) }
        wait(for: [delivered], timeout: 5)

        // Nothing more is readable, so a correct pump is now parked in its
        // `poll()` having issued exactly the one read. A pump that waits
        // inside `read()` instead has already issued its second one, within
        // microseconds of the callback returning. Poll for a bounded window
        // rather than sleeping a fixed amount: this fails as soon as the
        // second read appears, and only spends the full window when passing.
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            guard relay.outboundReadCount == 1 else { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(relay.outboundReadCount, 1,
                       "with nothing readable the pump must be waiting in poll(), not parked "
                     + "inside read(remoteFD, …) — shutdown() cannot reliably interrupt a "
                     + "blocked read, and its join loop has no deadline to fall back on")

        close(relay.localFD)
        relay.shutdown()
    }
}
