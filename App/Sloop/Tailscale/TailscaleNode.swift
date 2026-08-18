// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
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

    private let lock = NSLock()
    private var handle: tailscale = -1
    private var started = false
    /// The URL the user must visit to authorize this device, once tsnet has
    /// asked for one. libtailscale's C API has no accessor for it: tsnet writes
    /// it to the log, so the log is where it's read from — see `watchLog`.
    private var pendingAuthURL: String?
    private var logPipe: Pipe?

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
        while Date() < deadline {
            if hasTailnetAddressLocked() { return }
            if let raw = pendingAuthURL, let url = URL(string: raw) {
                throw NodeError.needsAuthorization(url)
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.25)
            lock.lock()
        }
        if let raw = pendingAuthURL, let url = URL(string: raw) {
            throw NodeError.needsAuthorization(url)
        }
        throw NodeError.tailscale("Sloop's tailnet node didn't come up: \(errorMessageLocked())")
    }

    /// Whether the node holds a tailnet address yet — the readiness test that
    /// doesn't block. Caller holds the lock.
    private func hasTailnetAddressLocked() -> Bool {
        var buffer = [CChar](repeating: 0, count: 256)
        guard tailscale_getips(handle, &buffer, buffer.count) == 0 else { return false }
        return !String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

        watchLog()

        guard tailscale_start(handle) == 0 else {
            throw NodeError.tailscale("Couldn't start Sloop's tailnet node: \(errorMessageLocked())")
        }
        started = true
    }

    /// tsnet's log is the only place the device-authorization URL appears, so
    /// it's read rather than discarded.
    private func watchLog() {
        let pipe = Pipe()
        logPipe = pipe
        _ = tailscale_set_logfd(handle, pipe.fileHandleForWriting.fileDescriptor)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let url = Self.authorizationURL(inLogOutput: text) else { return }
            guard let self else { return }
            self.lock.lock()
            self.pendingAuthURL = url
            self.lock.unlock()
        }
    }

    /// Pull the device-authorization URL out of a chunk of tsnet log output.
    /// Exposed for testing — the format is upstream's and worth pinning.
    static func authorizationURL(inLogOutput text: String) -> String? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,)"))
            if candidate.hasPrefix("https://login.tailscale.com/a/")
                || candidate.contains("/a/") && candidate.hasPrefix("https://") && candidate.contains("tailscale") {
                return candidate
            }
        }
        return nil
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
