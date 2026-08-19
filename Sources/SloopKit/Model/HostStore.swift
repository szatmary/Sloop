// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A small JSON-file store for saved hosts. Persistence only — no networking,
/// no secrets. Secrets are the keychain's job.
///
/// **It never loses a record it could not read.** Hosts are decoded one at a
/// time, and any record this build cannot understand — a host written by a
/// newer build, carrying a `connectionMethod` this one has never heard of — is
/// carried through to the next write verbatim. It used to be skipped on load
/// and then dropped from the file by the next `upsert`/`remove`, so editing
/// one host silently deleted another, minutes or days later, with nothing to
/// see. A file that cannot be parsed at all is moved aside rather than
/// overwritten, so the only copy of the user's hosts survives to be recovered
/// by hand. `KnownHostsStore` protects the user's host keys exactly this way,
/// for exactly these reasons.
public final class HostStore {
    /// Why a store refused to write.
    public enum StoreError: Error, LocalizedError {
        case unreadableFileCouldNotBeMovedAside(URL, underlying: Error)
        case hostsDidNotEncodeAsRecords

        public var errorDescription: String? {
            switch self {
            case .unreadableFileCouldNotBeMovedAside(let url, let underlying):
                return "the host file at \(url.path) could not be read and could not be "
                    + "moved aside (\(underlying.localizedDescription)), so it was left "
                    + "untouched rather than overwritten — the hosts in it are the only copy"
            case .hostsDidNotEncodeAsRecords:
                return "the host list did not encode as a JSON array of objects, so nothing "
                    + "was written — writing anyway would replace every saved host"
            }
        }
    }

    private let url: URL
    public private(set) var hosts: [SSHHost] = []

    /// Records this build could not decode, kept exactly as they were read so
    /// they survive a rewrite. Invisible to this build — it cannot make sense
    /// of them — but intact for the build that can.
    private var unparsedRecords: [[String: Any]] = []

    /// True when the file exists but is not readable/parseable as a whole, in
    /// which case it must be moved aside before anything is written.
    private var fileUnparseable = false

    /// - Parameter fileURL: where the host list lives. Required, not defaulted:
    ///   the app and the File Provider extension are separate processes that
    ///   must read the *same* file, and a default pointing at whichever
    ///   process's private Application Support directory happened to be asked
    ///   would leave the extension enumerating an empty host list — every
    ///   domain reporting that its host no longer exists. See `SloopStorage`.
    public init(fileURL: URL) {
        self.url = fileURL
        load()
    }

    public func load() {
        hosts = []
        unparsedRecords = []
        fileUnparseable = false

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Only "there is no file" means a fresh install. Every other read
            // failure — a permissions problem, an I/O error, a half-migrated
            // container — means a file exists that we must not clobber.
            let error = error as NSError
            let missing = error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
            fileUnparseable = !missing
            return
        }

        // A zero-byte file is damage, not absence: an interrupted or
        // out-of-space write leaves exactly this behind.
        guard !data.isEmpty else {
            fileUnparseable = true
            return
        }

        // JSONSerialization rather than JSONDecoder, so one unreadable record
        // costs one host instead of the whole list — and so the record can be
        // kept as it was written, which no `Decodable` view of it could do.
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let records = raw as? [[String: Any]] else {
            fileUnparseable = true
            return
        }

        for record in records {
            if let host = Self.decodeHost(record) {
                hosts.append(host)
            } else {
                unparsedRecords.append(record)
            }
        }
    }

    /// One record, decoded on its own terms. Returns nil for anything this
    /// build can't make an `SSHHost` of — including a `connectionMethod` it
    /// doesn't know, which `SSHHost`'s decoder rejects on purpose rather than
    /// quietly downgrading to a direct connection.
    private static func decodeHost(_ record: [String: Any]) -> SSHHost? {
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return nil }
        return try? JSONDecoder().decode(SSHHost.self, from: data)
    }

    public func save() throws {
        // Never write over a file we could not read: it holds the user's only
        // copy of their hosts and may be recoverable by hand. Moving it aside
        // must succeed, or we write nothing — a `try?` here would let the
        // write below destroy exactly what the move exists to rescue.
        if fileUnparseable {
            do {
                try FileManager.default.moveItem(at: url, to: uniqueQuarantineURL())
            } catch {
                throw StoreError.unreadableFileCouldNotBeMovedAside(url, underlying: error)
            }
            fileUnparseable = false
        }

        // Encode through JSONSerialization so the records this build couldn't
        // read can be written back beside the ones it could, untouched. They
        // land at the end: this build cannot know where they belong in a list
        // it can't read, and order is only meaningful to a build that can.
        let encoded = try JSONEncoder().encode(hosts)
        guard let mine = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] else {
            // `[SSHHost]` encodes to an array of objects or not at all, so
            // this is unreachable — and must stay an error rather than an
            // empty array, which would write a file that has lost every host.
            throw StoreError.hostsDidNotEncodeAsRecords
        }
        let data = try JSONSerialization.data(withJSONObject: mine + unparsedRecords)
        try data.write(to: url, options: [.atomic])
    }

    /// A quarantine name that never overwrites an earlier rescue — the oldest
    /// copy is the one most likely to hold the user's original hosts.
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

    /// Insert a new host or replace the existing one with the same `id`.
    public func upsert(_ host: SSHHost) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        forget(unparsedRecordFor: host.id)
        try? save()
    }

    public func remove(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        forget(unparsedRecordFor: host.id)
        try? save()
    }

    /// Drop a carried-through record the user has just deliberately replaced
    /// or deleted. Without this, saving over an id we couldn't read would
    /// leave two records claiming it, and deleting such a host wouldn't.
    private func forget(unparsedRecordFor id: UUID) {
        unparsedRecords.removeAll {
            ($0["id"] as? String)?.caseInsensitiveCompare(id.uuidString) == .orderedSame
        }
    }
}
