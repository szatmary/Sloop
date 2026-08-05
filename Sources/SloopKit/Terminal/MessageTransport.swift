import Foundation

/// A transport that prints a fixed message to the terminal and immediately
/// closes. Used as a graceful fallback when a real transport isn't available in
/// the current build (e.g. an SSH build that hasn't linked libssh2 yet), so the
/// UI shows an explanation instead of a dead screen.
public final class MessageTransport: Transport {
    public var onData: ((ArraySlice<UInt8>) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let message: String

    public init(message: String) { self.message = message }

    public func start() {
        onData?(ArraySlice(Array(message.utf8)))
        onClose?(nil)
    }

    public func send(_ bytes: ArraySlice<UInt8>) {}
    public func resize(cols: Int, rows: Int) {}
    public func close() { onClose?(nil) }
}
