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
/// Three properties matter more here than in an ordinary cache, because this
/// file is the only thing standing between the user and a man-in-the-middle.
///
/// **It fails closed.** A record that cannot be read is reported as
/// `.mismatch`, never `.unknown`. `.unknown` shows the trust-on-first-use
/// prompt, which is exactly what an attacker who can corrupt one line wants;
/// `.mismatch` refuses and makes the user re-verify deliberately.
///
/// **It never loses a pin it could not parse.** Records are parsed one at a
/// time, and any record this build cannot understand is carried through to the
/// next write verbatim. So a damaged or future-format record keeps failing its
/// endpoint closed across launches instead of evaporating on the next unrelated
/// save — and a file that cannot be parsed at all is moved aside, never
/// overwritten.
///
/// **Access is serialized.** One store is shared by every connection and SSH
/// connections run on their own threads — a Mosh host alone runs two, its
/// bootstrap probe and its shell. Unsynchronized mutation here is memory
/// corruption, not a lost update.
public final class KnownHostsStore: @unchecked Sendable {
    private struct Entry: Codable, Equatable {
        var endpoint: String
        var keyType: String
        var fingerprint: String
    }

    /// Why a store refused to write.
    public enum StoreError: Error, LocalizedError {
        case unreadableFileCouldNotBeMovedAside(URL, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .unreadableFileCouldNotBeMovedAside(let url, let underlying):
                return "the known-hosts file at \(url.path) could not be read and could "
                    + "not be moved aside (\(underlying.localizedDescription)), so it was "
                    + "left untouched rather than overwritten — the host keys in it are "
                    + "the only copy"
            }
        }
    }

    private let url: URL
    private let lock = NSLock()
    /// Keyed by endpoint, so a duplicate endpoint is impossible by construction.
    private var entries: [String: Entry]
    /// Records this build could not parse, kept exactly as they were read so
    /// they survive a rewrite. Any that name an endpoint fail that endpoint
    /// closed; the rest are carried purely so nothing is destroyed.
    private var unparsedRecords: [[String: Any]]
    /// Endpoints named by an unparsed record — the fail-closed set.
    private var unreadableEndpoints: Set<String>
    /// True when the file exists but is not readable/parseable as a whole, in
    /// which case it must be moved aside before anything is written.
    private var fileUnparseable: Bool

    /// - Parameter fileURL: where the database lives. Required, not defaulted:
    ///   the app and the File Provider extension are separate processes that
    ///   must consult the *same* file, and a default pointing at whichever
    ///   process's private Application Support directory happened to be asked
    ///   would give the extension an empty known-hosts database — which fails
    ///   closed on every host and reads to the user as "Sloop suddenly distrusts
    ///   my servers". See `SloopStorage`.
    public init(fileURL: URL) {
        self.url = fileURL

        self.entries = [:]
        self.unparsedRecords = []
        self.unreadableEndpoints = []
        self.fileUnparseable = false

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Only "there is no file" means a fresh install. Every other read
            // failure — a permissions problem, an I/O error, a half-migrated
            // container — means a file exists that we must not clobber.
            //
            // Which error that is depends on the platform: Darwin's Foundation
            // reports a Cocoa error, while swift-corelibs-foundation passes the
            // raw ENOENT through as NSPOSIXErrorDomain. Matching only the Cocoa
            // codes made every fresh install on Linux look like a damaged file,
            // which put the store into its quarantine path — and quarantining a
            // file that isn't there fails, so no host key could ever be pinned.
            let ns = error as NSError
            let missing = (ns.domain == NSCocoaErrorDomain
                           && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError))
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
            self.fileUnparseable = !missing
            return
        }

        // A zero-byte file is damage, not absence: an interrupted or
        // out-of-space write leaves exactly this behind.
        guard !data.isEmpty else {
            self.fileUnparseable = true
            return
        }

        // JSONSerialization rather than JSONDecoder, so one malformed record
        // costs one pin instead of aborting the whole array. Decoding
        // `[[String: String]]` looks per-record but is not: a single non-string
        // value anywhere throws for the entire file.
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let records = raw as? [[String: Any]] else {
            self.fileUnparseable = true
            return
        }

        for record in records {
            if let endpoint = record["endpoint"] as? String,
               let keyType = record["keyType"] as? String,
               let fingerprint = record["fingerprint"] as? String {
                entries[endpoint] = Entry(endpoint: endpoint, keyType: keyType,
                                          fingerprint: fingerprint)
            } else {
                unparsedRecords.append(record)
                if let endpoint = record["endpoint"] as? String {
                    unreadableEndpoints.insert(endpoint)
                }
            }
        }
    }

    public static func endpoint(host: String, port: Int) -> String { "\(host):\(port)" }

    /// Compare an observed key against what we've recorded for this endpoint.
    public func status(endpoint: String, keyType: String, fingerprint: String) -> KnownHostStatus {
        lock.lock()
        defer { lock.unlock() }

        // Checked first: a damaged record for this endpoint must refuse even if
        // an intact one also exists, since we cannot tell which is authentic.
        if unreadableEndpoints.contains(endpoint) { return .mismatch }
        guard let existing = entries[endpoint] else { return .unknown }
        return (existing.keyType == keyType && existing.fingerprint == fingerprint)
            ? .match : .mismatch
    }

    /// The key we currently have on record for an endpoint, if any. Used to show
    /// the user what changed when a key no longer matches.
    public func recorded(endpoint: String) -> (keyType: String, fingerprint: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let existing = entries[endpoint] else { return nil }
        return (existing.keyType, existing.fingerprint)
    }

    /// Whether this endpoint's record exists but could not be read, so the
    /// caller can say "your record was damaged, re-verify" rather than
    /// presenting a changed-key warning with nothing to compare against.
    public func isUnreadable(endpoint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return unreadableEndpoints.contains(endpoint)
    }

    /// Record (or replace) the key for an endpoint. Call this after a successful
    /// trust-on-first-use, or when the user explicitly accepts a changed key.
    ///
    /// Throws if the pin could not be written. A silently failed write is worse
    /// here than elsewhere: a failed `forget` leaves a revoked key trusted at
    /// the next launch, with no prompt and nothing to see.
    public func remember(endpoint: String, keyType: String, fingerprint: String) throws {
        lock.lock()
        defer { lock.unlock() }
        entries[endpoint] = Entry(endpoint: endpoint, keyType: keyType, fingerprint: fingerprint)
        // Deliberately trusting an endpoint clears its damaged record.
        unreadableEndpoints.remove(endpoint)
        unparsedRecords.removeAll { ($0["endpoint"] as? String) == endpoint }
        try persistLocked()
    }

    public func forget(endpoint: String) throws {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: endpoint)
        unreadableEndpoints.remove(endpoint)
        unparsedRecords.removeAll { ($0["endpoint"] as? String) == endpoint }
        try persistLocked()
    }

    /// Caller must hold `lock`.
    private func persistLocked() throws {
        // Never write over a file we could not read: it holds the user's only
        // copy of their pins and may be recoverable by hand. Moving it aside
        // must succeed, or we write nothing — a `try?` here would let the write
        // below destroy exactly what the move exists to rescue.
        if fileUnparseable {
            let quarantine = uniqueQuarantineURL()
            do {
                try FileManager.default.moveItem(at: url, to: quarantine)
            } catch {
                throw StoreError.unreadableFileCouldNotBeMovedAside(url, underlying: error)
            }
            fileUnparseable = false
        }

        // Records this build could not parse are written back untouched, so a
        // damaged or future-format pin keeps failing its endpoint closed
        // instead of disappearing on the next unrelated save.
        let mine = entries.values.map {
            ["endpoint": $0.endpoint, "keyType": $0.keyType, "fingerprint": $0.fingerprint]
                as [String: Any]
        }
        let all = mine.sorted { ($0["endpoint"] as? String ?? "") < ($1["endpoint"] as? String ?? "") }
            + unparsedRecords
        let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted])
        try data.write(to: url, options: [.atomic])
    }

    /// A quarantine name that never overwrites an earlier rescue — the oldest
    /// copy is the one most likely to hold the user's original pins.
    private func uniqueQuarantineURL() -> URL {
        let base = url.lastPathComponent + ".unreadable"
        let dir = url.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base).\(n)")
            n += 1
        }
        return candidate
    }
}
