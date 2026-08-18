// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// Sources/SloopKit/Net/SocketPairRelay.swift
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Bridges a byte stream that exists only as callbacks (e.g. WebSocket frames)
/// to a real socket fd, so libssh2 can treat a tunneled stream like a plain
/// TCP connection.
///
/// One end of a `socketpair` is handed out as `localFD` (give it to libssh2;
/// the caller closes it). The relay owns the other end: `receive(_:)` makes
/// remote bytes readable on `localFD`; bytes written to `localFD` surface via
/// `onOutbound`. Blocking writes against the pair's small kernel buffers give
/// natural backpressure in both directions.
///
/// Threading: `onOutbound` and `onLocalClosed` are always invoked on the
/// relay's own private pump thread (spun up by `start()`), never on `main`.
/// Callers that touch UI state from these callbacks must hop threads
/// themselves.
///
/// Lifecycle: `shutdown()` is the *only* teardown path, and it is safe to
/// call more than once, including concurrently with in-flight `receive()`/
/// `finishInbound()` calls from another thread — Task 7 drives this relay
/// from URLSession's delegate queue while the SSH side can be tearing down
/// on its own thread, so that overlap is the normal case, not an edge case.
/// It is *also* safe to call `shutdown()` reentrantly from inside either
/// pump callback — `onLocalClosed` (the natural `onLocalClosed = {
/// relay.shutdown() }` wiring) or `onOutbound` (e.g. tearing down after a
/// send times out, which is what Task 7's dialer does) — even though both
/// run on the relay's own pump thread, before the pump has finished
/// exiting. See the comment on `shutdown()` for why the thread join is
/// skipped in that case, and on `pumpOutbound()` for what actually makes
/// skipping it safe for *every* reentrant caller, not just the one that
/// happens to return immediately afterward.
/// There is no `deinit` safety net: the pump thread's `[weak self]` capture
/// only guards the instant before `pumpOutbound()` starts running — once it
/// starts, the call keeps `self` strongly retained for the pump's entire
/// lifetime, so the relay cannot be deallocated until `shutdown()` makes the
/// pump exit.
public final class SocketPairRelay {
    public let localFD: Int32
    private let remoteFD: Int32

    /// Read end of the pump's teardown-wakeup pipe: the pump waits on this
    /// alongside `remoteFD` (see `waitForOutboundBytes()`), so `shutdown()`
    /// can unpark it without depending on the socket layer to do it.
    ///
    /// Round-4 finding, and the reason this pipe exists at all: on Darwin,
    /// `shutdown(fd, SHUT_RDWR)` returning 0 does *not* reliably unpark a
    /// `read(fd)` that another thread is already blocked in. Measured on
    /// macOS 26.5 (Darwin 25.5) with a minimal two-thread C repro — one
    /// thread parked in `read()` on one end of an `AF_UNIX` `socketpair`,
    /// another calling `shutdown(SHUT_RDWR)` on that same end — the reader
    /// stayed parked forever in 24 of 5,000 runs (~0.5%), with `shutdown()`
    /// returning 0 every time. The window is under a microsecond wide:
    /// teardown has to land within ~1 µs of the reader entering the syscall.
    /// Calling `shutdown()` a second time does not help: the read
    /// side is already marked shut, so the second call short-circuits with
    /// `ENOTCONN` before it would re-issue the wakeup. Only closing the
    /// *peer* fd frees the reader — which is exactly what `shutdown()` is
    /// not allowed to do yet, since it must first know the pump has stopped
    /// touching `remoteFD`. That deadlocked `shutdown()`'s join loop
    /// permanently; it is a teardown-path hang, i.e. every session close is
    /// a coin flip.
    ///
    /// `poll()`, unlike a blocked `read()`, *is* reliably woken by that same
    /// `shutdown()` (0 hangs in 50,000 iterations of the same repro), so
    /// polling before reading would have been enough on its own. The pipe is
    /// nonetheless the primary mechanism, because it makes the pump's exit
    /// depend on nothing but this class's own state: `shutdown()` writes one
    /// byte that is never read back, so the wake is level-triggered and
    /// permanent — any poll entered afterward returns immediately — rather
    /// than a one-shot edge that a badly-timed park could miss.
    private let wakeReadFD: Int32
    /// Write end of the wakeup pipe. Written exactly once, one byte, by the
    /// single `shutdown()` call that gets past the idempotency guard — so it
    /// can never block on a full pipe.
    private let wakeWriteFD: Int32

    /// Guards `teardownCommitted`, `deliberateTeardown`, `started`, and
    /// `activeFDUsers` together as one state machine — small, fast
    /// transitions only, never held across a blocking syscall (see
    /// `receive()`'s comment) — and doubles as the wait/signal condition for
    /// "`activeFDUsers` has reached zero". It has to be *the same* lock for
    /// both jobs: checking `teardownCommitted` and incrementing `activeFDUsers`
    /// (in `beginUsingFD()`) must be one atomic step so no caller can start
    /// a new use of `remoteFD` after `shutdown()` has committed to closing
    /// it, and `shutdown()`'s wait for `activeFDUsers == 0` (in
    /// `endUsingFD()`) needs to observe that same counter under that same
    /// lock to avoid missing a signal. `NSCondition` is a lock (`lock()`/
    /// `unlock()`) that also supports `wait()`/`signal()`, which is exactly
    /// this shape.
    private let lock = NSCondition()
    private var teardownCommitted = false
    private var deliberateTeardown = false
    private var started = false
    private var activeFDUsers = 0

    /// Backing storage for `remoteFDClosed`, below — guarded by `lock` on
    /// both the read and the write side (see that property's comment).
    private var remoteFDClosedStorage = false

    /// True only once `close(remoteFD)` has actually run, at the very end of
    /// `shutdown()` — unlike `teardownCommitted`, which flips true the
    /// instant `shutdown()` is *entered*, before the poison/join/drain
    /// sequence even starts. `internal` (the default access level) so tests
    /// can observe the real difference between "`shutdown()` returned" and
    /// "`shutdown()` actually freed the fd" via `@testable import` — a
    /// second, idempotent `shutdown()` call proves neither, since its
    /// early-return guard fires identically whether or not `close()` ever
    /// ran. A computed property, not a stored `private(set)` one, so the
    /// read goes through `lock` the same as the write does — a Bool this
    /// small is exactly the kind of access TSan flags when only one side of
    /// it is synchronized, and nothing here guarantees a happens-before edge
    /// between the write in `shutdown()` and an arbitrary reader otherwise.
    var remoteFDClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return remoteFDClosedStorage
    }

    /// Backing storage for `outboundReadCount`, below — guarded by `lock`,
    /// same reasoning as `remoteFDClosedStorage`. Only ever written on the
    /// pump thread, but read from arbitrary test threads.
    private var outboundReadCountStorage = 0

    /// Total number of `read(remoteFD, …)` calls `pumpOutbound()` has
    /// issued. `internal`, test-only instrumentation — the one
    /// non-timing-dependent way to prove "the pump performed no further
    /// read" after a reentrant `shutdown()` call from `onOutbound` (see
    /// `SocketPairRelayTests.testOnOutboundShutdownStopsThePumpFromReadingAgain`).
    /// A plain "did the pump exit promptly" check can't distinguish the bug
    /// from the fix on its own: the extra `read()` the bug performs targets
    /// an fd number `shutdown()` just closed, which — absent something else
    /// in the process reusing that exact number in that instant — fails
    /// fast with EBADF either way, so the pump exits "promptly" whether or
    /// not that extra syscall happened. Counting attempts, not inferring
    /// from what a stray one would return, is what makes the assertion
    /// deterministic instead of dependent on fd-recycling timing.
    ///
    /// Incremented immediately *before* each `read()`, not after it returns,
    /// so it really is a count of attempts: a `read()` the pump is currently
    /// blocked inside has already been counted. That is what lets
    /// `testPumpNeverParksInsideRead` observe the difference between a pump
    /// waiting in `poll()` and one parked inside `read()` — a distinction
    /// that decides whether `shutdown()` can interrupt it at all, and which
    /// is invisible to a counter that only records completed reads.
    var outboundReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outboundReadCountStorage
    }

    /// The pump thread, captured so `shutdown()` (and `pumpOutbound()`
    /// itself) can tell whether it is being called/running *from* that
    /// thread — reentrantly, via `onLocalClosed` or `onOutbound` — versus
    /// from anywhere else.
    private var pumpThread: Thread?

    /// Broadcast once by `pumpOutbound()` right before it returns, so
    /// `shutdown()` can wait for the pump to actually stop touching
    /// `remoteFD` before freeing its fd number.
    ///
    /// `broadcast()`, not `signal()`: there are two places that can be
    /// parked here — `shutdown()`'s join loop and `waitUntilPumpExits` — and
    /// the pump only ever passes through this once. A `signal()` would wake
    /// exactly one of them and strand the other; `shutdown()`'s loop has no
    /// deadline, so stranding *it* is a permanent hang. The wakeup happens
    /// once per relay lifetime, so waking a waiter that has nothing to do
    /// costs nothing.
    private let pumpDone = NSCondition()
    private var pumpHasExited = false

    /// Bytes the local side (libssh2) wrote, to be carried to the remote.
    /// Fires *on the pump thread itself*; an owner that calls `shutdown()`
    /// reentrantly from here (e.g. tearing down after a send timeout, as
    /// Task 7's dialer does) is supported — see `shutdown()` and
    /// `pumpOutbound()`.
    public var onOutbound: ((Data) -> Void)?
    /// The local side closed its fd, or the pair broke unexpectedly; pumping
    /// has stopped. Never fires as a result of the owner calling
    /// `shutdown()` — only when the local side went away on its own. Fires
    /// *on the pump thread itself*; an owner that calls `shutdown()` from
    /// here (the natural thing to do) is calling it reentrantly, which is
    /// supported — see `shutdown()`.
    public var onLocalClosed: (() -> Void)?

    public init() throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, sockStreamType, 0, &fds) == 0 else {
            throw SSHError.connectionFailed("socketpair failed: errno \(errno)")
        }
        // A write after the peer closes must surface as EPIPE, not SIGPIPE.
        #if canImport(Darwin)
        for fd in fds {
            var one: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                let failure = errno
                close(fds[0])
                close(fds[1])
                throw SSHError.connectionFailed("setsockopt(SO_NOSIGPIPE) failed: errno \(failure)")
            }
        }
        #endif
        var wake: [Int32] = [0, 0]
        guard pipe(&wake) == 0 else {
            let failure = errno
            close(fds[0])
            close(fds[1])
            throw SSHError.connectionFailed("pipe failed: errno \(failure)")
        }
        localFD = fds[0]
        remoteFD = fds[1]
        wakeReadFD = wake[0]
        wakeWriteFD = wake[1]
    }

    /// Begin pumping. Set `onOutbound`/`onLocalClosed` before calling.
    public func start() {
        let thread = Thread { [weak self] in self?.pumpOutbound() }
        thread.name = "org.szatmary.sloop.relay"
        lock.lock()
        started = true
        pumpThread = thread
        lock.unlock()
        thread.start()
    }

    /// Feed bytes from the remote toward the local side. Blocks for
    /// backpressure; safe (a no-op) once the local side has closed or the
    /// relay has been shut down. The blocking write itself is never done
    /// under `lock` — only the cheap bookkeeping in `beginUsingFD`/
    /// `endUsingFD` is — so a blocking write here can never stall a
    /// concurrent `shutdown()` (or vice versa).
    public func receive(_ data: Data) {
        guard beginUsingFD() else { return }
        defer { endUsingFD() }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = sendNoSignal(remoteFD, base.advanced(by: offset), raw.count - offset)
                if n < 0 && errno == EINTR { continue }   // interrupted, not an error — retry
                if n <= 0 { return }   // EPIPE, or shutdown() poisoned the pair
                offset += n
            }
        }
    }

    /// The remote sent EOF: after any buffered bytes, reads on `localFD`
    /// return 0 so libssh2 sees a normal connection close.
    public func finishInbound() {
        guard beginUsingFD() else { return }
        defer { endUsingFD() }
        // Unqualified `shutdown` here would resolve to the `shutdown()`
        // instance method below, not the libc call — qualify explicitly.
        #if canImport(Darwin)
        Darwin.shutdown(remoteFD, Int32(SHUT_WR))
        #elseif canImport(Glibc)
        Glibc.shutdown(remoteFD, Int32(SHUT_WR))
        #endif
    }

    /// Tear down the relay's end. Idempotent, and safe to call concurrently
    /// with another thread's in-flight `receive()`/`finishInbound()`:
    /// `remoteFD`'s number is never freed while another caller could still
    /// be about to use it. `shutdown(remoteFD, SHUT_RDWR)` poisons the fd
    /// first — it unblocks the pump's blocked `read()` and makes any
    /// in-flight or subsequent `receive()`/`finishInbound()` return
    /// promptly (via `beginUsingFD` rejecting new callers once
    /// `teardownCommitted` is set, and existing blocking syscalls failing once
    /// the endpoint is poisoned) — without freeing the fd number. Only once
    /// (a) the pump thread has actually exited and (b) every caller that
    /// was already inside `receive()`/`finishInbound()` has left do we
    /// `close()` the fd, which is the point the OS is free to recycle its
    /// number.
    ///
    /// Safe to call *reentrantly from the pump thread itself* — both the
    /// normal `onLocalClosed = { relay.shutdown() }` wiring and a callback
    /// like `onOutbound` tearing down after its own timeout — because both
    /// callbacks fire from inside `pumpOutbound()`, before its `defer` marks
    /// `pumpHasExited`. Joining the pump in that case would be the pump
    /// thread waiting for itself to finish: a guaranteed deadlock.
    /// `pumpThread` lets us detect that case and skip the join. Skipping it
    /// is only safe because `pumpOutbound()` itself guarantees it won't
    /// touch `remoteFD` again after this call commits to closing it — see
    /// that method's comment for how; it is *not* enough that "the callback
    /// is on its way out," since `onOutbound` fires mid-loop and would
    /// otherwise read `remoteFD` again right after returning here.
    public func shutdown() {
        lock.lock()
        guard !teardownCommitted else { lock.unlock(); return }
        teardownCommitted = true
        deliberateTeardown = true
        let wasStarted = started
        let calledFromPumpThread = Thread.current === pumpThread
        lock.unlock()

        // Unpark the pump first, and out of band of the socket entirely: the
        // socket poison below is what stops *other* threads' in-flight
        // `receive()`/`finishInbound()` calls, but it cannot be relied on to
        // free a pump already parked waiting on `remoteFD` (see
        // `wakeReadFD`). One byte, never read back, so the wake is permanent
        // rather than a one-shot the pump could park just after.
        var poke: UInt8 = 1
        _ = write(wakeWriteFD, &poke, 1)

        #if canImport(Darwin)
        Darwin.shutdown(remoteFD, Int32(SHUT_RDWR))
        #elseif canImport(Glibc)
        Glibc.shutdown(remoteFD, Int32(SHUT_RDWR))
        #endif

        if wasStarted && !calledFromPumpThread {
            pumpDone.lock()
            while !pumpHasExited {
                pumpDone.wait()
            }
            pumpDone.unlock()
        }

        lock.lock()
        while activeFDUsers > 0 {
            lock.wait()
        }
        lock.unlock()

        close(remoteFD)
        // Safe at exactly the same point `remoteFD` is: the pump is the only
        // user of these, and it has either exited (joined above) or — in the
        // reentrant-from-a-callback case, where the join is skipped — is
        // guaranteed by `pumpOutbound()`'s teardown checks to return without
        // polling again. Anything weaker than that would be a use-after-close
        // on the wakeup pipe instead of on the socket.
        close(wakeReadFD)
        close(wakeWriteFD)

        lock.lock()
        remoteFDClosedStorage = true
        lock.unlock()
    }

    /// Registers a `receive()`/`finishInbound()` call as about to touch
    /// `remoteFD`, unless teardown has already been committed. The check
    /// and the increment happen under the same `lock` `shutdown()` sets
    /// `teardownCommitted` under, so there is no window where a new caller can
    /// start after `shutdown()` has decided to close the fd.
    private func beginUsingFD() -> Bool {
        lock.lock()
        guard !teardownCommitted else { lock.unlock(); return false }
        activeFDUsers += 1
        lock.unlock()
        return true
    }

    private func endUsingFD() {
        lock.lock()
        activeFDUsers -= 1
        // `broadcast()` for the same reason as `pumpDone`'s: the wait this
        // releases (`shutdown()`'s drain loop) has no deadline, so waking
        // the wrong single waiter would hang rather than merely delay.
        if activeFDUsers == 0 { lock.broadcast() }
        lock.unlock()
    }

    /// Whether `shutdown()` has committed to closing `remoteFD` (and the
    /// wakeup pipe) — used by `pumpOutbound()` to decide whether it may
    /// safely touch either of them again. See that method's comment.
    private func isTeardownCommitted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return teardownCommitted
    }

    /// Test-only: block until the pump thread has actually returned from
    /// `pumpOutbound()`, or the timeout elapses. Returns whether it exited
    /// in time. Deliberately does *not* go through a second `shutdown()`
    /// call to observe this — once teardown is already committed (e.g. by a
    /// reentrant call from `onOutbound`), a second `shutdown()` call returns
    /// immediately via its own idempotency guard without waiting for
    /// anything, so it would prove nothing either way (the same vacuous-test
    /// trap `remoteFDClosed` exists to avoid — see its comment).
    func waitUntilPumpExits(timeout: TimeInterval) -> Bool {
        pumpDone.lock()
        defer { pumpDone.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !pumpHasExited {
            guard pumpDone.wait(until: deadline) else { return false }
        }
        return true
    }

    /// The pump loop. Its governing invariant, on which `shutdown()`'s
    /// pump-thread join skip depends: once this method invokes *either*
    /// callback, it must not touch `remoteFD` again if that callback caused
    /// teardown to be committed. That was true "for free" for
    /// `onLocalClosed` — it's the last thing on its branch before an
    /// unconditional `return` — but `onOutbound` fires mid-loop, with
    /// another `read(remoteFD, …)` waiting right after it; a reentrant
    /// `shutdown()` call from inside `onOutbound` (e.g. tearing down after a
    /// send timeout) closes `remoteFD` on this same thread — via the
    /// pump-thread branch in `shutdown()`, which skips joining *this* method
    /// because it assumes nothing but its `defer` is left to run here — so
    /// looping back into `read` would reissue a syscall against an fd number
    /// the OS may already have handed to something else entirely. Hence the
    /// `isTeardownCommitted()` check after *every* callback invocation,
    /// below: it's what makes that assumption actually true. The matching
    /// check at the top of the loop extends the same guarantee to the wakeup
    /// pipe `waitForOutboundBytes()` polls, which `shutdown()` closes at the
    /// same moment it closes `remoteFD`.
    ///
    /// Where the loop *waits* is the round-4 change: on `poll()`, not inside
    /// `read()`. A blocked `read()` is not reliably freed by the
    /// `shutdown(remoteFD, SHUT_RDWR)` that teardown issues, which used to
    /// leave this method parked forever and `shutdown()`'s join loop parked
    /// behind it — see `wakeReadFD` for the measurement.
    private func pumpOutbound() {
        defer {
            pumpDone.lock()
            pumpHasExited = true
            pumpDone.broadcast()
            pumpDone.unlock()
        }
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            if isTeardownCommitted() { return }
            guard waitForOutboundBytes() else { return }
            lock.lock()
            outboundReadCountStorage += 1
            lock.unlock()
            let n = read(remoteFD, &buffer, buffer.count)
            if n > 0 {
                onOutbound?(Data(buffer[0..<n]))
                if isTeardownCommitted() { return }
            } else if n == 0 || errno != EINTR {
                lock.lock()
                let deliberate = deliberateTeardown
                lock.unlock()
                if !deliberate {
                    onLocalClosed?()
                }
                // Unconditional regardless of what onLocalClosed did — this
                // branch never loops back into read() either way, which is
                // what has always made a reentrant shutdown() from here
                // safe. Checking isTeardownCommitted() here too would be
                // redundant, not incorrect; omitted so the one that matters,
                // above, isn't lost among decorative ones.
                return
            }
        }
    }

    /// Parks the pump until `remoteFD` has something to report — bytes, EOF,
    /// or an error, all of which `poll` reports as readable — or `shutdown()`
    /// pokes the wakeup pipe. Returns `false` when the pump must stop without
    /// reading `remoteFD` again.
    ///
    /// This is the blocking wait the pump used to do inside `read()` itself.
    /// It moved out here because a parked `read()` is not reliably freed by
    /// `shutdown()`, while a parked `poll()` is — see `wakeReadFD`. The
    /// `read()` that follows a readable `poll` still blocks in principle, but
    /// only until it has consumed what `poll` just said was there, so it is
    /// no longer where the pump waits.
    private func waitForOutboundBytes() -> Bool {
        var fds = [
            pollfd(fd: remoteFD, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeReadFD, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            let ready = poll(&fds, nfds_t(fds.count), -1)
            if ready < 0 {
                if errno == EINTR { continue }   // interrupted, not an error — retry
                return false
            }
            // Teardown wins over any pending bytes: once `shutdown()` has
            // committed, `remoteFD`'s number is on its way to being freed and
            // nothing may issue another syscall against it.
            if fds[1].revents != 0 { return false }
            if fds[0].revents != 0 { return true }
        }
    }

    private func sendNoSignal(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return write(fd, buf, count)          // SO_NOSIGPIPE is set
        #else
        return send(fd, buf, count, Int32(MSG_NOSIGNAL))
        #endif
    }
}
