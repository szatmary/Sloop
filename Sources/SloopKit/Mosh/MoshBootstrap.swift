import Foundation

/// Parsed handshake produced by starting `mosh-server` over SSH.
///
/// Mosh connects in two stages:
///
///   1. SSH into the host and run `mosh-server new -s -c 256 ...`. It prints a
///      line of the form `MOSH CONNECT <udp-port> <base64-key>` and daemonizes.
///   2. Close the SSH connection, then speak the Mosh State-Synchronization
///      Protocol (SSP) to that UDP port using the key. SSP is what lets a
///      session survive IP changes, sleep, and flaky links.
///
/// This type captures step 1's output. The datagram half (step 2) is C++ and
/// must be cross-compiled for Apple targets — see `Docs/MOSH.md` — and will live
/// behind a `MoshTransport: Transport` once that binary exists.
public struct MoshBootstrap: Equatable {
    public let udpPort: Int
    public let key: String

    public init(udpPort: Int, key: String) {
        self.udpPort = udpPort
        self.key = key
    }

    /// Parse the `MOSH CONNECT <port> <key>` line out of the mosh-server banner.
    /// Returns `nil` if no such line is present.
    public init?(serverBanner banner: String) {
        for line in banner.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 4,
                  parts[0] == "MOSH", parts[1] == "CONNECT",
                  let port = Int(parts[2]) else { continue }
            self.udpPort = port
            self.key = String(parts[3])
            return
        }
        return nil
    }
}
