// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A `Transport` that implements "prefer Mosh, fall back to SSH".
///
/// When Mosh is requested it first bootstraps `mosh-server` over an SSH exec
/// channel (a `CommandRunner`). Depending on the result it activates either a
/// Mosh transport or a plain SSH shell, then transparently forwards the whole
/// `Transport` surface to whichever one is live. The user sees a short notice in
/// the terminal explaining which mode they got.
///
/// It composes other transports and a command runner through injected factories,
/// so the branching is unit-testable with mocks — no network, no Mac.
///
/// Note: probing costs an extra short-lived SSH exec connection, and on a host
/// that *has* Mosh but no Mosh transport is wired yet (`makeMoshTransport ==
/// nil`), the started `mosh-server` is left to time out (~60s) while we use SSH.
/// Both go away once the Mosh UDP/SSP transport lands and actually consumes the
/// bootstrap.
public final class MoshOrSSHTransport: Transport, SessionCommandRunner {
    public var onData: ((ArraySlice<UInt8>) -> Void)?
    public var onOpen: (() -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let useMosh: Bool
    private let makeCommandRunner: () -> CommandRunner
    private let makeSSHTransport: () -> Transport
    private let makeMoshTransport: ((MoshBootstrap) -> Transport)?
    private let afterDelay: (TimeInterval, @escaping () -> Void) -> Void

    /// How long a Mosh session may say nothing at all before the terminal
    /// explains what that usually means.
    ///
    /// Only the *first* packet is timed. Silence later is Mosh working as
    /// designed — see the "deliberately no server-went-quiet timeout" note in
    /// `MoshBridge.mm` — but silence from the start is a different animal: the
    /// bootstrap proved the host is reachable over TCP, so nothing arriving on
    /// UDP points at a filtered path rather than a dozing peer. Long enough
    /// that a slow cellular first round trip won't trip it.
    public static let firstPacketNotice: TimeInterval = 8

    /// Receives the host's shell history, read on the Mosh bootstrap channel.
    ///
    /// Mosh's only SSH connection is the one that starts `mosh-server`, and it
    /// is gone before the terminal opens — so unlike an SSH session, there is
    /// nothing left to ask afterwards. Set this before `start()`; left nil,
    /// nothing is read.
    public var onShellHistory: ((String) -> Void)?

    /// Guards everything below: the bootstrap completion arrives on the probe's
    /// worker thread while `send`/`resize`/`close` are called from the main one.
    private let lock = NSLock()
    /// The transport currently carrying data (SSH shell or Mosh), once chosen.
    private var active: Transport?
    /// Held so the command runner survives the async probe — the libssh2 runner
    /// captures itself weakly on its worker thread, so a temporary would
    /// deallocate before the completion fires.
    private var bootstrapper: MoshBootstrapper?

    /// Input and geometry that arrived while the probe was still running.
    ///
    /// Choosing Mosh takes a full SSH connect, auth and exec round trip, and the
    /// terminal is live throughout: SwiftTerm reports its size during that
    /// window and the user can type into it. Dropping those on the floor cost a
    /// visible bug — the remote terminal kept mosh's 80×24 default while the
    /// real view was wider, so the server drew frames for the wrong geometry and
    /// the screen came out garbled in a way that looks like broken emulation.
    /// SwiftTerm only reports a size *change*, so on a device that never rotates
    /// the mistake is never corrected.
    private var pendingBytes: [UInt8] = []
    private var pendingResize: (cols: Int, rows: Int)?
    /// Set by `close()`, whatever stage we are at. Before activation it stops
    /// the probe's completion opening a connection nobody owns; after it, it
    /// stops anything writing into a terminal that is already gone.
    private var isClosed = false
    /// Whether the live transport has ever produced a byte. Distinguishes "the
    /// session is quiet" from "the session never started".
    private var sawTransportData = false

    public init(useMosh: Bool,
                makeCommandRunner: @escaping () -> CommandRunner,
                makeSSHTransport: @escaping () -> Transport,
                makeMoshTransport: ((MoshBootstrap) -> Transport)? = nil,
                afterDelay: @escaping (TimeInterval, @escaping () -> Void) -> Void = { seconds, work in
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
                }) {
        self.useMosh = useMosh
        self.makeCommandRunner = makeCommandRunner
        self.makeSSHTransport = makeSSHTransport
        self.makeMoshTransport = makeMoshTransport
        self.afterDelay = afterDelay
    }

    public func start() {
        guard useMosh else {
            activate(makeSSHTransport())
            return
        }

        emit("[sloop] mosh: probing server…\r\n")
        let bootstrapper = MoshBootstrapper(runner: makeCommandRunner())
        bootstrapper.onShellHistory = onShellHistory
        self.bootstrapper = bootstrapper
        bootstrapper.bootstrap { [weak self] startup in
            guard let self else { return }
            self.bootstrapper = nil   // probe done; release the runner
            switch startup {
            case .connect(let bootstrap):
                if let makeMosh = self.makeMoshTransport {
                    self.emit("[sloop] mosh: connected (udp \(bootstrap.udpPort))\r\n")
                    self.activate(makeMosh(bootstrap))
                    self.noticeIfNothingArrives(onUDPPort: bootstrap.udpPort)
                } else {
                    self.emit("[sloop] mosh: available, but the Mosh transport isn't built yet — using SSH\r\n")
                    self.activate(self.makeSSHTransport())
                }
            case .unavailable(let reason):
                self.emit("[sloop] mosh: \(reason) — using SSH\r\n")
                self.activate(self.makeSSHTransport())
            }
        }
    }

    public func send(_ bytes: ArraySlice<UInt8>) {
        lock.lock()
        if let active {
            lock.unlock()
            active.send(bytes)
            return
        }
        pendingBytes.append(contentsOf: bytes)
        lock.unlock()
    }

    public func resize(cols: Int, rows: Int) {
        lock.lock()
        if let active {
            lock.unlock()
            active.resize(cols: cols, rows: rows)
            return
        }
        // Only the latest matters — the terminal has one size.
        pendingResize = (cols, rows)
        lock.unlock()
    }

    public func close() {
        lock.lock()
        let live = active
        // A close during the probe must still take effect: without this the
        // completion activates a fresh connection for a tab the user already
        // closed, which nobody owns and nothing will ever close.
        isClosed = true
        lock.unlock()
        live?.close()
    }

    /// Adopt `transport` as the live one and forward its callbacks out.
    private func activate(_ transport: Transport) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        active = transport
        let resize = pendingResize
        let bytes = pendingBytes
        pendingResize = nil
        pendingBytes.removeAll()
        lock.unlock()

        transport.onData = { [weak self] bytes in
            self?.noteDataArrived()
            self?.onData?(bytes)
        }
        transport.onOpen = { [weak self] in self?.onOpen?() }
        transport.onClose = { [weak self] error in self?.onClose?(error) }

        // Size before start: MoshTransport reads its geometry when it creates
        // the session, so a resize applied afterwards would leave the first
        // frames drawn at the wrong width.
        if let resize { transport.resize(cols: resize.cols, rows: resize.rows) }
        transport.start()
        if !bytes.isEmpty { transport.send(bytes[...]) }
    }

    private func noteDataArrived() {
        lock.lock()
        sawTransportData = true
        lock.unlock()
    }

    /// Say something when a Mosh session never makes a sound.
    ///
    /// Without this the terminal reads "mosh: connected (udp 60007)" and then
    /// stays blank forever, which looks like Sloop hanging when it is really
    /// the network dropping SSP packets — the common causes being a firewall
    /// that allows 22 and nothing else, and a NAT with no inbound mapping.
    /// Upstream mosh-client has the same warning for the same reason.
    ///
    /// It only reports. Killing the session here would be wrong: packets can
    /// still turn up, and outlasting silence is the whole point of Mosh.
    private func noticeIfNothingArrives(onUDPPort port: Int) {
        afterDelay(Self.firstPacketNotice) { [weak self] in
            guard let self else { return }
            lock.lock()
            let quiet = !sawTransportData && !isClosed
            lock.unlock()
            guard quiet else { return }
            emit("[sloop] mosh: nothing received on UDP port \(port) after "
                 + "\(Int(Self.firstPacketNotice))s. SSH reached this host, so UDP is likely "
                 + "blocked between here and it. Still listening — Mosh survives silence.\r\n")
        }
    }

    /// Forward to whichever transport is live, if it can run a command at all.
    ///
    /// A Mosh session cannot: its SSH connection existed only long enough to
    /// start `mosh-server` and is gone by the time anything asks. Saying so
    /// plainly beats appearing to work.
    public func runOnSession(_ command: String, completion: @escaping (String?) -> Void) {
        lock.lock()
        let live = active
        lock.unlock()
        guard let runner = live as? SessionCommandRunner else { return completion(nil) }
        runner.runOnSession(command, completion: completion)
    }

    private func emit(_ text: String) {
        onData?(ArraySlice(Array(text.utf8)))
    }
}
