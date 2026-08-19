// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
#if canImport(os)
import os
#endif

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

    #if canImport(os)
    private static let log = Logger(subsystem: "org.szatmary.sloop", category: "mosh")
    #endif

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

    /// Questions registered before the session picked a transport — see
    /// `requestOnSession`. They ride the bootstrap when there is one, because
    /// for a Mosh session that is the only connection there will ever be; a
    /// session with no bootstrap hands them to whatever it activates instead.
    /// Every entry is answered exactly once and then dropped, so a completion
    /// can never fire twice or be left holding a caller forever.
    private var pendingRequests: [(command: String, completion: (String?) -> Void)] = []
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
        // Whatever was registered before now rides the bootstrap. Taken under
        // the lock and left in place: `answerPendingRequests` clears the queue
        // once the outputs are back, so `activate` won't hand them on again.
        lock.lock()
        bootstrapper.extraCommands = pendingRequests.map(\.command)
        lock.unlock()
        self.bootstrapper = bootstrapper
        bootstrapper.bootstrap { [weak self] result in
            guard let self else { return }
            self.bootstrapper = nil   // probe done; release the runner
            // Before activation, so the answers are delivered whichever
            // transport the probe chose — and so a fallback to SSH doesn't open
            // a second channel to re-ask what the bootstrap already answered.
            self.answerPendingRequests(with: result.extraOutputs)
            switch result.startup {
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
        let stranded = pendingRequests
        pendingRequests.removeAll()
        lock.unlock()
        // There is no connection left to ask on, and saying so is what lets the
        // caller stop waiting — a completion that never fires strands it, and
        // whatever it captured, for the life of the process.
        for request in stranded { request.completion(nil) }
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
        // Anything still queued was never carried by a bootstrap — there wasn't
        // one, or it arrived after the probe's commands were fixed.
        let requests = pendingRequests
        pendingResize = nil
        pendingBytes.removeAll()
        pendingRequests.removeAll()
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
        // Questions before start too, for the same shape of reason: that is the
        // contract `SessionCommandRunner` states, and an SSH transport wants
        // them in hand before its event loop makes its first pass.
        for request in requests { forward(request, to: transport) }
        transport.start()
        if !bytes.isEmpty { transport.send(bytes[...]) }
    }

    /// Hand the bootstrap's answers to whoever asked, in the order they were
    /// registered, and empty the queue so nothing is asked or answered twice.
    private func answerPendingRequests(with outputs: [String?]) {
        lock.lock()
        let answered = Array(pendingRequests.prefix(outputs.count))
        pendingRequests.removeFirst(answered.count)
        lock.unlock()
        for (request, output) in zip(answered, outputs) { request.completion(output) }
    }

    private func forward(_ request: (command: String, completion: (String?) -> Void),
                         to transport: Transport) {
        guard let runner = transport as? SessionCommandRunner else {
            return request.completion(nil)
        }
        runner.requestOnSession(request.command, completion: request.completion)
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

    /// Queue the question until this session knows what it is, then answer it
    /// from the cheapest connection it has.
    ///
    /// Before the session picks a transport, the answer isn't knowable: a Mosh
    /// session must ask on its bootstrap exec and an SSH one on a second
    /// channel once the shell is up, and which of those this is takes a full
    /// connect, auth and exec round trip to discover. Queuing is what lets one
    /// caller cover both.
    ///
    /// Asked *after* the session is live, it can only forward — and a live Mosh
    /// session has nothing left to forward to, so it says nil. That is not a
    /// limitation to route around with a second, Mosh-shaped API; it is the
    /// reason to register before `start()`.
    public func requestOnSession(_ command: String, completion: @escaping (String?) -> Void) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return completion(nil)
        }
        guard let live = active else {
            pendingRequests.append((command, completion))
            lock.unlock()
            return
        }
        lock.unlock()
        forward((command, completion), to: live)
    }

    private func emit(_ text: String) {
        // Also to the system log: these lines are the record of which
        // transport a session got and why, and on a device the terminal they
        // are written to may be gone by the time anyone asks. os_log rather
        // than print so they survive however the app was launched — a print
        // only reaches a debugger or a console-attached launch.
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(os)
        Self.log.info("\(line, privacy: .public)")
        #endif
        #if DEBUG
        // A device console shows stdout, not the unified log, and the unified
        // log can only be collected with root on the Mac. During bring-up the
        // console is the only channel that actually reaches whoever is holding
        // the iPad.
        print(line)
        #endif
        onData?(ArraySlice(Array(text.utf8)))
    }
}
