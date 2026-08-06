import Foundation

/// A bidirectional byte stream between the terminal UI and some backend: a local
/// echo loop, an SSH channel, or a Mosh session.
///
/// The contract is deliberately tiny so the UI layer never needs to know which
/// kind of connection it is talking to. Bytes flow from the remote end via
/// `onData`; keystrokes flow to the remote end via `send`.
public protocol Transport: AnyObject {
    /// Invoked when bytes arrive from the remote end and should be fed to the
    /// terminal. May be called on a background queue; the UI layer is
    /// responsible for hopping to the main thread before touching views.
    var onData: ((ArraySlice<UInt8>) -> Void)? { get set }

    /// Invoked once when the transport is established and ready to carry data
    /// (after connect/auth for SSH; immediately for local transports). May be
    /// called on a background queue. Lets the UI show "connected".
    var onOpen: (() -> Void)? { get set }

    /// Invoked once when the transport closes, with an optional error.
    var onClose: ((Error?) -> Void)? { get set }

    /// Open the transport. Results are reported asynchronously via `onData` /
    /// `onClose`.
    func start()

    /// Send user input (keystrokes) to the remote end.
    func send(_ bytes: ArraySlice<UInt8>)

    /// Inform the remote of a new terminal size, in character cells.
    func resize(cols: Int, rows: Int)

    /// Close the transport. `onClose` fires exactly once as a result.
    func close()
}
