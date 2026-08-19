// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import os
import SloopKit
#if SLOOP_TAILSCALE
import CTailscale

/// Sloop's own node on the user's tailnet, via `libtailscale` (tsnet).
///
/// Userspace WireGuard: no VPN entitlement, no system VPN slot — which matters
/// on iOS, where only one VPN may be active, so requiring the Tailscale app
/// would mean the user could not run any other. `tailscale_dial` returns a real
/// socket fd, so a tailnet host reaches libssh2 through exactly the same
/// `Dialer` seam as a direct TCP connect.
///
/// One node per *process role*, not per host: a tsnet node is a device on the
/// tailnet with its own key and its own entry in the admin console. Several
/// would appear as several devices, each needing its own login.
///
/// There are exactly two roles, and they are two devices on purpose. The app
/// and the File Provider extension are separate processes, and the extension
/// runs while the app does not — so they cannot take turns with one identity.
/// Sharing a state directory would mean one node key on two connections, which
/// the control plane sees as a single device flapping between endpoints, and
/// which breaks both. The visible cost is a second entry in the admin console
/// (`sloop-<device>-files`) needing its own one-time authorization; the
/// alternative is a Files integration that only works while the terminal is
/// closed.
public final class TailscaleNode: @unchecked Sendable {
    private static let lock = NSLock()
    private static var nodes: [SloopStorage.TailnetRole: TailscaleNode] = [:]

    /// The node for this process's role, created once.
    public static func node(for role: SloopStorage.TailnetRole) -> TailscaleNode {
        lock.lock(); defer { lock.unlock() }
        if let existing = nodes[role] { return existing }
        let node = TailscaleNode(role: role)
        nodes[role] = node
        return node
    }

    /// Where the node keeps its identity — its node key, above all. Losing this
    /// directory means the tailnet sees a *new* device, which the user has to
    /// authorize again and then clean up in the admin console, so it lives in
    /// the App Group container (backed up, not purgeable) rather than Caches.
    private let role: SloopStorage.TailnetRole

    private static let log = Logger(subsystem: "org.szatmary.sloop", category: "tailnet")

    private let lock = NSLock()
    private var handle: tailscale = -1
    private var started = false

    private init(role: SloopStorage.TailnetRole) {
        self.role = role
    }

    /// `UserActionRequiredError` because neither case clears itself: the node
    /// needs a person to authorize the device, or a problem fixed in the app.
    /// Without it the File Provider extension retried the dial forever instead
    /// of showing the user somewhere to go.
    enum NodeError: LocalizedError, UserActionRequiredError {
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
    public func dialUDP(host: String, port: Int) throws -> Int32 {
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
        try SloopStorage.tailnetStateDirectory(
            role: role, in: try SloopStorage.sharedDirectory())
    }

    /// The name this device shows up under in the admin console. The extension
    /// gets a `-files` suffix so the two entries are tellable apart by someone
    /// looking at the console wondering why their iPad is listed twice.
    private func deviceName() -> String {
        #if os(iOS)
        let device = UIDevice.current.name
        #else
        let device = Host.current().localizedName ?? "mac"
        #endif
        let base = "sloop-" + device.lowercased().replacingOccurrences(of: " ", with: "-")
        return role == .fileProvider ? base + "-files" : base
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
