import Foundation

/// Skeleton libssh2-backed transport.
///
/// libssh2 is not yet vendored into the project. On Apple platforms it must be
/// built as an `.xcframework` (arm64 device + simulator + macOS + tvOS slices)
/// and linked into the app target — see `Docs/SSH.md` for the build recipe.
///
/// Until that lands, `start()` reports `.notImplemented` so the UI can fall back
/// to `EchoTransport`. The method bodies below mark exactly where the libssh2
/// calls go, so wiring it up is a fill-in-the-blanks job rather than a redesign.
public final class LibSSH2Transport: Transport {
    public var onData: ((ArraySlice<UInt8>) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let host: Host
    private let credential: Credential
    private let queue = DispatchQueue(label: "org.szatmary.sloop.ssh")

    public init(host: Host, credential: Credential) {
        self.host = host
        self.credential = credential
    }

    public func start() {
        // TODO(ssh):
        //   1. Open a TCP socket to host.hostname:host.port.
        //   2. libssh2_session_init / libssh2_session_handshake.
        //   3. Verify the host key against a known_hosts store.
        //   4. Authenticate per host.auth using `credential`.
        //   5. libssh2_channel_open_session + request_pty("xterm-256color").
        //   6. Start a shell; pump channel reads into `onData` on `queue`.
        onClose?(SSHError.notImplemented("libssh2 transport not wired up yet — see Docs/SSH.md"))
    }

    public func send(_ bytes: ArraySlice<UInt8>) {
        // TODO(ssh): libssh2_channel_write on the shell channel.
    }

    public func resize(cols: Int, rows: Int) {
        // TODO(ssh): libssh2_channel_request_pty_size(cols, rows).
    }

    public func close() {
        // TODO(ssh): channel_close + session_disconnect + socket close.
        onClose?(nil)
    }
}
