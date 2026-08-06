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
public final class MoshOrSSHTransport: Transport {
    public var onData: ((ArraySlice<UInt8>) -> Void)?
    public var onOpen: (() -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let useMosh: Bool
    private let makeCommandRunner: () -> CommandRunner
    private let makeSSHTransport: () -> Transport
    private let makeMoshTransport: ((MoshBootstrap) -> Transport)?

    /// The transport currently carrying data (SSH shell or Mosh), once chosen.
    private var active: Transport?
    /// Held so the command runner survives the async probe — the libssh2 runner
    /// captures itself weakly on its worker thread, so a temporary would
    /// deallocate before the completion fires.
    private var bootstrapper: MoshBootstrapper?

    public init(useMosh: Bool,
                makeCommandRunner: @escaping () -> CommandRunner,
                makeSSHTransport: @escaping () -> Transport,
                makeMoshTransport: ((MoshBootstrap) -> Transport)? = nil) {
        self.useMosh = useMosh
        self.makeCommandRunner = makeCommandRunner
        self.makeSSHTransport = makeSSHTransport
        self.makeMoshTransport = makeMoshTransport
    }

    public func start() {
        guard useMosh else {
            activate(makeSSHTransport())
            return
        }

        emit("[sloop] mosh: probing server…\r\n")
        let bootstrapper = MoshBootstrapper(runner: makeCommandRunner())
        self.bootstrapper = bootstrapper
        bootstrapper.bootstrap { [weak self] startup in
            guard let self else { return }
            self.bootstrapper = nil   // probe done; release the runner
            switch startup {
            case .connect(let bootstrap):
                if let makeMosh = self.makeMoshTransport {
                    self.emit("[sloop] mosh: connected (udp \(bootstrap.udpPort))\r\n")
                    self.activate(makeMosh(bootstrap))
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

    public func send(_ bytes: ArraySlice<UInt8>) { active?.send(bytes) }
    public func resize(cols: Int, rows: Int) { active?.resize(cols: cols, rows: rows) }
    public func close() { active?.close() }

    /// Adopt `transport` as the live one and forward its callbacks out.
    private func activate(_ transport: Transport) {
        active = transport
        transport.onData = { [weak self] bytes in self?.onData?(bytes) }
        transport.onOpen = { [weak self] in self?.onOpen?() }
        transport.onClose = { [weak self] error in self?.onClose?(error) }
        transport.start()
    }

    private func emit(_ text: String) {
        onData?(ArraySlice(Array(text.utf8)))
    }
}
