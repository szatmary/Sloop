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
/// It is *also* safe to call `shutdown()` reentrantly from inside the
/// `onLocalClosed` callback (the natural thing for an owner to do, and
/// exactly what Task 7's dialer does) even though that callback runs on the
/// relay's own pump thread, before the pump has finished exiting — see the
/// comment on `shutdown()` for why that doesn't deadlock.
/// There is no `deinit` safety net: the pump thread's `[weak self]` capture
/// only guards the instant before `pumpOutbound()` starts running — once it
/// starts, the call keeps `self` strongly retained for the pump's entire
/// lifetime, so the relay cannot be deallocated until `shutdown()` makes the
/// pump exit.
public final class SocketPairRelay {
    public let localFD: Int32
    private let remoteFD: Int32

    /// Guards `remoteClosed`, `deliberateTeardown`, `started`, and
    /// `activeFDUsers` together as one state machine — small, fast
    /// transitions only, never held across a blocking syscall (see
    /// `receive()`'s comment) — and doubles as the wait/signal condition for
    /// "`activeFDUsers` has reached zero". It has to be *the same* lock for
    /// both jobs: checking `remoteClosed` and incrementing `activeFDUsers`
    /// (in `beginUsingFD()`) must be one atomic step so no caller can start
    /// a new use of `remoteFD` after `shutdown()` has committed to closing
    /// it, and `shutdown()`'s wait for `activeFDUsers == 0` (in
    /// `endUsingFD()`) needs to observe that same counter under that same
    /// lock to avoid missing a signal. `NSCondition` is a lock (`lock()`/
    /// `unlock()`) that also supports `wait()`/`signal()`, which is exactly
    /// this shape.
    private let lock = NSCondition()
    private var remoteClosed = false
    private var deliberateTeardown = false
    private var started = false
    private var activeFDUsers = 0

    /// The pump thread, captured so `shutdown()` can tell whether it is
    /// being called *from* that thread (reentrantly, via `onLocalClosed`)
    /// versus from anywhere else.
    private var pumpThread: Thread?

    /// Signaled once by `pumpOutbound()` right before it returns, so
    /// `shutdown()` can wait for the pump to actually stop touching
    /// `remoteFD` before freeing its fd number.
    private let pumpDone = NSCondition()
    private var pumpHasExited = false

    /// Bytes the local side (libssh2) wrote, to be carried to the remote.
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
        localFD = fds[0]
        remoteFD = fds[1]
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
    /// `remoteClosed` is set, and existing blocking syscalls failing once
    /// the endpoint is poisoned) — without freeing the fd number. Only once
    /// (a) the pump thread has actually exited and (b) every caller that
    /// was already inside `receive()`/`finishInbound()` has left do we
    /// `close()` the fd, which is the point the OS is free to recycle its
    /// number.
    ///
    /// Safe to call *reentrantly from the pump thread itself* — the normal
    /// shape of `onLocalClosed = { relay.shutdown() }` — because
    /// `onLocalClosed` fires from inside `pumpOutbound()`, before its
    /// `defer` marks `pumpHasExited`. Joining the pump in that case would
    /// be the pump thread waiting for itself to finish: a guaranteed
    /// deadlock. `pumpThread` lets us detect that case and skip the join;
    /// the pump is already on its way out (that's *why* the callback
    /// fired), so nothing but the `defer` is left to run there.
    public func shutdown() {
        lock.lock()
        guard !remoteClosed else { lock.unlock(); return }
        remoteClosed = true
        deliberateTeardown = true
        let wasStarted = started
        let calledFromPumpThread = Thread.current === pumpThread
        lock.unlock()

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
    }

    /// Registers a `receive()`/`finishInbound()` call as about to touch
    /// `remoteFD`, unless teardown has already been committed. The check
    /// and the increment happen under the same `lock` `shutdown()` sets
    /// `remoteClosed` under, so there is no window where a new caller can
    /// start after `shutdown()` has decided to close the fd.
    private func beginUsingFD() -> Bool {
        lock.lock()
        guard !remoteClosed else { lock.unlock(); return false }
        activeFDUsers += 1
        lock.unlock()
        return true
    }

    private func endUsingFD() {
        lock.lock()
        activeFDUsers -= 1
        if activeFDUsers == 0 { lock.signal() }
        lock.unlock()
    }

    private func pumpOutbound() {
        defer {
            pumpDone.lock()
            pumpHasExited = true
            pumpDone.signal()
            pumpDone.unlock()
        }
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = read(remoteFD, &buffer, buffer.count)
            if n > 0 {
                onOutbound?(Data(buffer[0..<n]))
            } else if n == 0 || errno != EINTR {
                lock.lock()
                let deliberate = deliberateTeardown
                lock.unlock()
                if !deliberate {
                    onLocalClosed?()
                }
                return
            }
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
