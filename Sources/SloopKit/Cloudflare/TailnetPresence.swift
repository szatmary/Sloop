// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Whether this device is currently on a tailnet.
///
/// Sloop reaches Tailscale hosts through the Tailscale app's system VPN rather
/// than by joining the tailnet itself, so "is Tailscale connected right now" is
/// the difference between a host that works and one that cannot be reached at
/// all. The device answers it: when the VPN is up, an interface carries an
/// address from Tailscale's assigned ranges, and when it is down, none does.
///
/// Worth checking before dialing rather than after. A tailnet name doesn't
/// resolve and a tailnet address isn't routable when Tailscale is off, so the
/// connect fails — eventually, as a timeout or a name-lookup error that says
/// nothing about the actual cause. Asking first turns that into one sentence
/// naming the thing to fix.
public enum TailnetPresence {
    /// Tailscale's IPv4 range: 100.64.0.0/10, the CGNAT block it uses for
    /// tailnet addresses.
    static func isTailnetIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        guard parts.count == 4,
              let first = UInt8(parts[0]), let second = UInt8(parts[1]),
              UInt8(parts[2]) != nil, UInt8(parts[3]) != nil else { return false }
        // 100.64.0.0/10 — the second octet's top two bits are fixed by the /10.
        return first == 100 && (64...127).contains(second)
    }

    /// Tailscale's IPv6 range: fd7a:115c:a1e0::/48.
    static func isTailnetIPv6(_ address: String) -> Bool {
        address.lowercased().hasPrefix("fd7a:115c:a1e0")
    }

    static func isTailnetAddress(_ address: String) -> Bool {
        isTailnetIPv4(address) || isTailnetIPv6(address)
    }

    /// True when any local interface holds a tailnet address.
    public static var isConnected: Bool {
        localAddresses().contains(where: isTailnetAddress)
    }

    /// Every address currently assigned to a local interface.
    private static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [String] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let raw = interface.pointee.ifa_addr else { continue }
            let family = raw.pointee.sa_family
            guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { continue }

            // Derived from the family, not read from `sa_len`: that field is a
            // BSD extension and does not exist on Linux, where this module is
            // compiled to hold its Foundation-only claim to account.
            let length = family == UInt8(AF_INET)
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(raw, length,
                                     &buffer, socklen_t(buffer.count),
                                     nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            var address = String(cString: buffer)
            // Link-local IPv6 arrives scoped ("fe80::1%en0"); the zone index is
            // not part of the address for matching purposes.
            if let percent = address.firstIndex(of: "%") {
                address = String(address[..<percent])
            }
            addresses.append(address)
        }
        return addresses
    }
}
