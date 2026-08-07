import Foundation
import SloopKit

// Only the Mosh-enabled build (project.mosh.yml) links mosh.xcframework and sets
// the bridging header that exposes the `mosh_session_*` C API, and it defines
// SLOOP_MOSH. The plain SSH build (project.ssh.yml) links libssh2 but not mosh,
// so gating on SLOOP_MOSH — not `canImport(CSSH)` — keeps this file (and the
// undefined C symbols it would reference) out of that build.
#if SLOOP_MOSH

/// A `Transport` that carries a Mosh (State-Synchronization Protocol) session
/// over UDP, driving the C++ mosh client core through `MoshBridge`.
///
/// The two-stage Mosh handshake is already done by the time we get here: SSH ran
/// `mosh-server`, which handed back a UDP port and a session key (`MoshBootstrap`).
/// This transport speaks SSP to `host:port` with that key. mosh syncs terminal
/// *state* (a framebuffer), so the bridge renders each new server framebuffer to
/// ANSI via mosh's own `Display::new_frame` and feeds it to SwiftTerm through
/// `onData`.
///
/// The bridge owns a dedicated network thread; callbacks arrive on it, and this
/// class forwards them out unchanged (the UI layer hops to the main thread).
final class MoshTransport: Transport {
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: ((Error?) -> Void)?

    private let host: String
    private let port: String
    private let key: String

    private var session: OpaquePointer?
    private var cols: Int = 80
    private var rows: Int = 24
    private var closed = false

    /// - Parameters:
    ///   - host: the hostname/IP the SSH connection reached (mosh reuses it for UDP).
    ///   - bootstrap: the `MOSH CONNECT <port> <key>` handshake from `mosh-server`.
    init(host: String, bootstrap: MoshBootstrap) {
        self.host = host
        self.port = String(bootstrap.udpPort)
        self.key = bootstrap.key
    }

    func start() {
        guard session == nil, !closed else { return }
        guard let s = mosh_session_create(host, port, key, Int32(cols), Int32(rows)) else {
            onClose?(MoshTransportError.createFailed)
            return
        }
        session = s

        // Retain self for the lifetime of the session; released in the close
        // trampoline so the object outlives every callback from the net thread.
        let ctx = Unmanaged.passRetained(self).toOpaque()
        mosh_session_set_callbacks(s, moshOutputTrampoline, moshCloseTrampoline, ctx)
        mosh_session_start(s)
        onOpen?()
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard let s = session else { return }
        let arr = Array(bytes)
        arr.withUnsafeBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { p in
                mosh_session_send(s, p, buf.count)
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        if let s = session {
            mosh_session_resize(s, Int32(cols), Int32(rows))
        }
    }

    func close() {
        guard let s = session else { return }
        mosh_session_close(s)
    }

    // MARK: Callbacks from the bridge (network thread)

    fileprivate func handleOutput(_ ptr: UnsafePointer<CChar>?, _ len: Int) {
        guard let ptr = ptr, len > 0, let onData = onData else { return }
        ptr.withMemoryRebound(to: UInt8.self, capacity: len) { p in
            onData(ArraySlice(UnsafeBufferPointer(start: p, count: len)))
        }
    }

    fileprivate func handleClose(_ reason: String?) {
        guard !closed else { return }
        closed = true
        let error = reason.map { MoshTransportError.session($0) }
        onClose?(error)
        // Tear down the bridge (joins the net thread) now that it has ended.
        if let s = session {
            session = nil
            mosh_session_destroy(s)
        }
    }
}

enum MoshTransportError: LocalizedError {
    case createFailed
    case session(String)

    var errorDescription: String? {
        switch self {
        case .createFailed: return "Couldn't start the Mosh session."
        case .session(let reason): return reason
        }
    }
}

// C function pointers can't capture context, so recover `self` from the opaque
// ctx. The output trampoline borrows it; the close trampoline consumes the
// retain taken in `start()` (exactly once — the bridge guarantees a single
// close callback).
private func moshOutputTrampoline(_ bytes: UnsafePointer<CChar>?,
                                  _ len: Int,
                                  _ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let transport = Unmanaged<MoshTransport>.fromOpaque(ctx).takeUnretainedValue()
    transport.handleOutput(bytes, len)
}

private func moshCloseTrampoline(_ reason: UnsafePointer<CChar>?,
                                 _ ctx: UnsafeMutableRawPointer?) {
    guard let ctx = ctx else { return }
    let unmanaged = Unmanaged<MoshTransport>.fromOpaque(ctx)
    let transport = unmanaged.takeUnretainedValue()
    transport.handleClose(reason.map { String(cString: $0) })
    unmanaged.release()
}

#endif  // SLOOP_MOSH
