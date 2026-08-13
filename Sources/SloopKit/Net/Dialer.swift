import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Produces the connected socket fd an SSH session runs over. This is the seam
/// tunnel integrations plug into: direct TCP today; Cloudflare Access and
/// Tailscale produce the same shape of fd by other means.
///
/// Contract: `dial()` is called at most once, on a background thread, and may
/// block. The returned fd is bidirectional and owned by the caller, who closes
/// it. The dialer instance must stay alive as long as the fd is in use (some
/// dialers pump the stream behind it).
public protocol Dialer: AnyObject {
    func dial() throws -> Int32
}

/// The status quo: resolve `host:port` and return a connected blocking TCP
/// socket.
public final class TCPDialer: Dialer {
    private let host: String
    private let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public func dial() throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = sockStreamType
        hints.ai_protocol = Int32(IPPROTO_TCP)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let addrs = result else {
            throw SSHError.connectionFailed("cannot resolve \(host)")
        }
        defer { freeaddrinfo(addrs) }

        var info: UnsafeMutablePointer<addrinfo>? = addrs
        while let candidate = info {
            let fd = socket(candidate.pointee.ai_family,
                            candidate.pointee.ai_socktype,
                            candidate.pointee.ai_protocol)
            if fd >= 0 {
                if connect(fd, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            info = candidate.pointee.ai_next
        }
        throw SSHError.connectionFailed("cannot connect to \(host):\(port)")
    }
}
