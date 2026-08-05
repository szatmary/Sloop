import Foundation
import SloopKit

/// Chooses a concrete `Transport` for a host. When the libssh2 xcframework is
/// linked (`CSSH` importable) it builds a real SSH connection; otherwise it
/// returns a `MessageTransport` explaining what's missing, so the app stays
/// usable during the libssh2 bring-up.
enum TransportFactory {
    static func ssh(host: SSHHost,
                    credential: Credential,
                    knownHosts: KnownHostsStore) -> Transport {
        #if canImport(CSSH)
        return LibSSH2Transport(host: host, credential: credential, knownHosts: knownHosts)
        #else
        return MessageTransport(message:
            "SSH isn't built into this app yet.\r\n" +
            "Add Vendor/libssh2.xcframework and rebuild — see Docs/SSH.md.\r\n\r\n" +
            "The Local terminal on the home screen works now.\r\n")
        #endif
    }
}
