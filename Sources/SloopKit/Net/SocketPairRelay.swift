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
public final class SocketPairRelay {
    public let localFD: Int32
    private let remoteFD: Int32
    private let lock = NSLock()
    private var remoteClosed = false

    /// Bytes the local side (libssh2) wrote, to be carried to the remote.
    public var onOutbound: ((Data) -> Void)?
    /// The local side closed its fd (or the pair broke); pumping has stopped.
    public var onLocalClosed: (() -> Void)?

    public init() throws {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, sockStreamType, 0, &fds) == 0 else {
            throw SSHError.connectionFailed("socketpair failed: errno \(errno)")
        }
        localFD = fds[0]
        remoteFD = fds[1]
        // A write after the peer closes must surface as EPIPE, not SIGPIPE.
        #if canImport(Darwin)
        for fd in fds {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        #endif
    }

    /// Begin pumping. Set `onOutbound`/`onLocalClosed` before calling.
    public func start() {
        let thread = Thread { [weak self] in self?.pumpOutbound() }
        thread.name = "org.szatmary.sloop.relay"
        thread.start()
    }

    /// Feed bytes from the remote toward the local side. Blocks for
    /// backpressure; safe (a no-op) after the local side closed.
    public func receive(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = sendNoSignal(remoteFD, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { return }   // EPIPE etc. — local side is gone
                offset += n
            }
        }
    }

    /// The remote sent EOF: after any buffered bytes, reads on `localFD`
    /// return 0 so libssh2 sees a normal connection close.
    public func finishInbound() {
        // Unqualified `shutdown` here would resolve to the `shutdown()`
        // instance method below, not the libc call — qualify explicitly.
        #if canImport(Darwin)
        Darwin.shutdown(remoteFD, Int32(SHUT_WR))
        #elseif canImport(Glibc)
        Glibc.shutdown(remoteFD, Int32(SHUT_WR))
        #endif
    }

    /// Tear down the relay's end. Call once the remote connection is finished.
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !remoteClosed else { return }
        remoteClosed = true
        close(remoteFD)
    }

    private func pumpOutbound() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = read(remoteFD, &buffer, buffer.count)
            if n > 0 {
                onOutbound?(Data(buffer[0..<n]))
            } else if n == 0 || errno != EINTR {
                onLocalClosed?()
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

#if canImport(Glibc)
private let sockStreamType = Int32(SOCK_STREAM.rawValue)
#else
private let sockStreamType = SOCK_STREAM
#endif
