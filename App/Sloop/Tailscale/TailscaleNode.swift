// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import os
import SloopKit
#if SLOOP_TAILSCALE

/// Sloop's own node on the user's tailnet, via `libtailscale` (tsnet).
///
/// Userspace WireGuard: no VPN entitlement, no system VPN slot — which matters
/// on iOS, where only one VPN may be active, so requiring the Tailscale app
/// would mean the user could not run any other. `tailscale_dial` returns a real
/// socket fd, so a tailnet host reaches libssh2 through exactly the same
/// `Dialer` seam as a direct TCP connect.
///
/// One node per app, not per host: a tsnet node is a device on the tailnet with
/// its own key and its own entry in the admin console. Several would appear as
/// several devices, each needing its own login.
final class TailscaleNode: @unchecked Sendable {
    static let shared = TailscaleNode()

    /// Where the node keeps its identity — its node key, above all. Losing this
    /// directory means the tailnet sees a *new* device, which the user has to
    /// authorize again and then clean up in the admin console, so it lives in
    /// Application Support (backed up, not purgeable) rather than Caches.
    private static let stateDirectoryName = "tailnet"

    private static let log = Logger(subsystem: "org.szatmary.sloop", category: "tailnet")

    private let lock = NSLock()
    private var handle: tailscale = -1
    private var started = false

    private init() {}

    enum NodeError: LocalizedError {
        case tailscale(String)
        case needsAuthorization(URL)

        var errorDescription: String? {
            switch self {
            case .tailscale(let message): return message
            case .needsAuthorization(let url):
                return "Sloop isn't on your tailnet yet. Authorize it at \(url.absoluteString), then reconnect."
            }
        }
    }

    /// Bring the node up far enough to dial, or say what's missing.
    ///
    /// Blocking on purpose: it's called from the SSH worker thread, where the
    /// dial it precedes blocks too.
    ///
    /// Deliberately *not* built on `tailscale_up`. That call blocks until the
    /// node is usable, which for an unauthorized device means until the user
    /// finishes a login it never told them about — the authorization URL only
    /// reaches us on the log, and nothing reads the log while a thread sits
    /// inside `up`. So: start (which returns immediately), then watch for
    /// whichever arrives first, an address or a URL to go and get one.
    func connect(timeout: TimeInterval = 30) throws {
        lock.lock()
        defer { lock.unlock() }

        if !started { try startLocked() }

        let deadline = Date().addingTimeInterval(timeout)
        var lastState = "Unknown"
        while Date() < deadline {
            let status = statusLocked()
            lastState = status.state
            if status.state == "Running" { return }
            if let raw = status.authURL, let url = URL(string: raw) {
                throw NodeError.needsAuthorization(url)
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.25)
            lock.lock()
        }
        throw NodeError.tailscale(
            "Sloop's tailnet node didn't come up — it's still \(lastState). " +
            "\(errorMessageLocked())")
    }

    /// What tsnet says it's doing: its backend state, and the URL to authorize
    /// this device when it's waiting for one. Caller holds the lock.
    ///
    /// Asked of tsnet directly rather than read out of its log — see
    /// `Scripts/libtailscale-sloop-status.go` for why the log is the wrong
    /// place to learn this.
    private func statusLocked() -> (state: String, authURL: String?) {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard TsnetSloopStatus(handle, &buffer, buffer.count) == 0 else {
            return ("Unknown", nil)
        }
        let lines = String(cString: buffer).split(separator: "\n", maxSplits: 1,
                                                  omittingEmptySubsequences: false)
        let state = lines.first.map(String.init) ?? "Unknown"
        let url = lines.count > 1 ? String(lines[1]) : ""
        return (state, url.isEmpty ? nil : url)
    }

    /// A connected socket to `host:port` over the tailnet.
    func dial(host: String, port: Int) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard started else {
            throw NodeError.tailscale("Sloop's tailnet node isn't running.")
        }
        var conn: tailscale_conn = -1
        let address = "\(host):\(port)"
        guard tailscale_dial(handle, "tcp", address, &conn) == 0 else {
            throw NodeError.tailscale("Couldn't reach \(address) over the tailnet: \(errorMessageLocked())")
        }
        return conn
    }

    /// A connected datagram socket to `host:port` over the tailnet, for Mosh.
    ///
    /// Not `tailscale_dial(…, "udp", …)`: that call reaches tsnet intact but
    /// returns a *stream* fd, and a stream has no message boundaries — two SSP
    /// packets would arrive as one read and fail to decrypt. `TsnetDialUDP` is
    /// Sloop's addition to libtailscale (`Scripts/libtailscale-sloop-udp.go`)
    /// and bridges through a datagram socketpair, so one write stays one
    /// packet.
    func dialUDP(host: String, port: Int) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard started else {
            throw NodeError.tailscale("Sloop's tailnet node isn't running.")
        }
        var conn: tailscale_conn = -1
        let address = "\(host):\(port)"
        // Logged, not just thrown: tsnet writes its own progress to stdout, so
        // a device console that shows the node coming up and then nothing is
        // ambiguous about whose fault the silence is.
        Self.log.info("dialing udp \(address, privacy: .public)")
        DeviceDiagnostics.log("tailnet: dialing udp \(address)")
        guard TsnetDialUDP(handle, address, &conn) == 0 else {
            Self.log.error("udp dial failed: \(self.errorMessageLocked(), privacy: .public)")
            DeviceDiagnostics.log("tailnet: udp dial FAILED — \(errorMessageLocked())")
            throw NodeError.tailscale(
                "Couldn't open a Mosh connection to \(address) over the tailnet: "
                + errorMessageLocked())
        }
        Self.log.info("udp fd \(conn) for \(address, privacy: .public)")
        DeviceDiagnostics.log("tailnet: udp fd \(conn) for \(address)")
        return conn
    }

    // MARK: - Internals

    private func startLocked() throws {
        let node = tailscale_new()
        guard node >= 0 else {
            throw NodeError.tailscale("Couldn't create a tailnet node.")
        }
        handle = node

        let directory = try stateDirectory()
        guard tailscale_set_dir(handle, directory.path) == 0 else {
            throw NodeError.tailscale("Couldn't use \(directory.path) for tailnet state: \(errorMessageLocked())")
        }
        // The name this device shows up under in the admin console. Without it
        // tsnet derives one from the executable, which on iOS is the same for
        // everyone running Sloop.
        _ = tailscale_set_hostname(handle, deviceName())

        guard tailscale_start(handle) == 0 else {
            throw NodeError.tailscale("Couldn't start Sloop's tailnet node: \(errorMessageLocked())")
        }
        started = true
    }

    private func stateDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent(Self.stateDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func deviceName() -> String {
        #if os(iOS)
        return "sloop-" + UIDevice.current.name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        #else
        return "sloop-" + (Host.current().localizedName ?? "mac").lowercased()
            .replacingOccurrences(of: " ", with: "-")
        #endif
    }

    /// The last error from libtailscale. Caller holds the lock.
    private func errorMessageLocked() -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        guard tailscale_errmsg(handle, &buffer, buffer.count) == 0 else {
            return "unknown error"
        }
        let message = String(cString: buffer)
        return message.isEmpty ? "unknown error" : message
    }
}

#if os(iOS)
import UIKit
#endif
#endif
