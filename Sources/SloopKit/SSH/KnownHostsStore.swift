// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// The result of checking a host key against what we've seen before.
public enum KnownHostStatus: Equatable {
    /// Never connected to this endpoint — trust-on-first-use applies.
    case unknown
    /// Key matches the one we recorded. Safe to proceed.
    case match
    /// Key differs from the recorded one, or the record for it could not be
    /// read. Possible MITM — refuse.
    case mismatch
}

/// A tiny known-hosts database, keyed by `host:port`.
///
/// Stores the host key type and a base64 fingerprint so we can detect when a
/// server's key changes between connections. Persistence is JSON; inject a
/// `fileURL` in tests. This is deliberately independent of any SSH library so it
/// unit-tests without a Mac.
///
/// Two properties matter more here than in an ordinary cache, because this file
/// is the only thing standing between the user and a man-in-the-middle:
///
/// - **It fails closed.** A record that cannot be read is reported as
///   `.mismatch`, not `.unknown`. Reporting `.unknown` would show the
///   trust-on-first-use prompt, which is precisely the outcome an attacker who
///   can corrupt one line wants; `.mismatch` refuses and makes the user
///   re-verify the key deliberately. A damaged record therefore blocks that one
///   endpoint and leaves every other host working.
/// - **It never destroys pins it could not parse.** The previous
///   implementation decoded the whole file with `try?` and fell back to an
///   empty list, so a single bad byte silently downgraded every host to
///   trust-on-first-use and the next `remember()` overwrote the file, making
///   the loss permanent and undetectable. An unparseable file is now moved
///   aside rather than overwritten.
///
/// Access is serialized: one store instance is shared by every connection (see
/// `HostListModel`), and SSH connections run on their own threads — a Mosh host
/// alone runs two. Unsynchronized mutation of the entry array from several
/// threads is memory corruption, not a lost update.
public final class KnownHostsStore {
    private struct Entry: Codable, Equatable {
        var endpoint: String
        var keyType: String
        var fingerprint: String
    }

    private let url: URL
    private let lock = NSLock()
    private var entries: [Entry]
    /// Endpoints whose stored record exists but could not be read. Kept
    /// separately so they fail closed instead of looking new.
    private var unreadableEndpoints: Set<String>
    /// True when the file existed but could not be parsed at all, in which case
    /// it is preserved rather than overwritten on the next write.
    private var fileUnparseable: Bool

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.url = fileURL
        } else {
            let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil,
                                                    create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.url = dir.appendingPathComponent("sloop-known-hosts.json")
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            // No file yet: a genuinely fresh install, where trust-on-first-use
            // is the correct behaviour.
            self.entries = []
            self.unreadableEndpoints = []
            self.fileUnparseable = false
            return
        }

        // Decoded one record at a time rather than as `[Entry]`, so a single
        // malformed record costs one pin instead of all of them. Every field is
        // a string, so the raw form round-trips through `[[String: String]]`.
        guard let raw = try? JSONDecoder().decode([[String: String]].self, from: data) else {
            self.entries = []
            self.unreadableEndpoints = []
            self.fileUnparseable = true
            return
        }

        var good: [Entry] = []
        var unreadable: Set<String> = []
        for record in raw {
            if let endpoint = record["endpoint"],
               let keyType = record["keyType"],
               let fingerprint = record["fingerprint"] {
                good.append(Entry(endpoint: endpoint, keyType: keyType, fingerprint: fingerprint))
            } else if let endpoint = record["endpoint"] {
                // We know which host this pin belonged to but not what it said:
                // fail that host closed.
                unreadable.insert(endpoint)
            }
            // A record without even an endpoint can't be attributed to a host;
            // there is nothing to fail closed on, and it is dropped.
        }
        self.entries = good
        self.unreadableEndpoints = unreadable
        self.fileUnparseable = false
    }

    public static func endpoint(host: String, port: Int) -> String { "\(host):\(port)" }

    /// Compare an observed key against what we've recorded for this endpoint.
    public func status(endpoint: String, keyType: String, fingerprint: String) -> KnownHostStatus {
        lock.lock()
        defer { lock.unlock() }

        if unreadableEndpoints.contains(endpoint) { return .mismatch }
        guard let existing = entries.first(where: { $0.endpoint == endpoint }) else {
            return .unknown
        }
        return (existing.keyType == keyType && existing.fingerprint == fingerprint)
            ? .match : .mismatch
    }

    /// The key we currently have on record for an endpoint, if any. Used to show
    /// the user what changed when a key no longer matches.
    public func recorded(endpoint: String) -> (keyType: String, fingerprint: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = entries.first(where: { $0.endpoint == endpoint }) else { return nil }
        return (existing.keyType, existing.fingerprint)
    }

    /// Record (or replace) the key for an endpoint. Call this after a successful
    /// trust-on-first-use, or when the user explicitly accepts a changed key.
    public func remember(endpoint: String, keyType: String, fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.endpoint == endpoint }
        entries.append(Entry(endpoint: endpoint, keyType: keyType, fingerprint: fingerprint))
        // An endpoint the user has just deliberately trusted is no longer
        // unreadable.
        unreadableEndpoints.remove(endpoint)
        try? persistLocked()
    }

    public func forget(endpoint: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.endpoint == endpoint }
        unreadableEndpoints.remove(endpoint)
        try? persistLocked()
    }

    /// Caller must hold `lock`.
    private func persistLocked() throws {
        // Never write over a file we could not parse: whatever is in there is
        // the user's only copy of their pins, and it may be recoverable by
        // hand. Move it aside first, keeping the failure visible on disk.
        if fileUnparseable {
            let quarantine = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".unreadable")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: url, to: quarantine)
            fileUnparseable = false
        }
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic])
    }
}
