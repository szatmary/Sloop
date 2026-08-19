// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import FileProvider
import SloopKit

/// Enumerates one remote directory, and reports what changed in it since the
/// last time the system asked.
///
/// **There is no change feed.** SFTP cannot push. So `enumerateChanges` re-lists
/// the directory and diffs it against the attributes `SFTPItemIndex` recorded
/// during the previous enumeration. The honest consequence, and it belongs in
/// the user-facing docs rather than a comment: a file changed by someone else
/// over SSH appears when Files.app next asks — a pull-to-refresh, or the
/// system's own schedule — not the moment it happens. Changes Sloop itself
/// makes are signalled immediately.
final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let service: SFTPDomainService
    private let container: NSFileProviderItemIdentifier

    init(service: SFTPDomainService, container: NSFileProviderItemIdentifier) {
        self.service = service
        self.container = container
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        // The working set is the system's own index — what it consults for
        // Spotlight, Recents, and for changes to already-materialized
        // directories. SFTP cannot push, so Sloop has nothing to put in it and
        // enumerates it as empty. Reporting it as an unknown item instead, which
        // is what happened before, tells the system the container was deleted.
        guard container != .workingSet else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        service.perform { [service, container] client, index in
            let directory = try service.path(for: container, client, index)
            let entries = try client.list(directory)
            // Record the listing even on a plain enumeration. Otherwise the
            // first enumerateChanges would diff against nothing and report
            // every existing item as newly added.
            index.apply(listing: entries, to: directory)
            try index.save()
            // One stat for the container, shared by every item in it: rename,
            // delete and move are governed by the directory's mode, not each
            // file's. Unknown stays unknown rather than becoming "forbidden".
            let containerIsWritable = (try? client.stat(directory))
                .map { $0.permissions & 0o200 != 0 }
            return try entries.map {
                try service.item(for: $0, client, index, parentIsWritable: containerIsWritable)
            }
        } completion: { result in
            switch result {
            case .success(let items):
                observer.didEnumerate(items)
                // One page: an SFTP readdir is already a full directory read,
                // so paginating would mean re-listing for each page and
                // presenting a directory that changed underneath itself.
                observer.finishEnumerating(upTo: nil)
            case .failure(let error):
                observer.finishEnumeratingWithError(FileProviderError.from(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        guard container != .workingSet else {
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }
        service.perform { [service, container] client, index in
            let directory = try service.path(for: container, client, index)
            let changes = index.apply(listing: try client.list(directory), to: directory)
            try index.save()
            return (changes: changes,
                    updated: try (changes.added + changes.updated)
                        .map { try service.item(for: $0, client, index) },
                    anchor: index.anchor)
        } completion: { result in
            switch result {
            case .success(let (changes, updated, anchor)):
                if !updated.isEmpty { observer.didUpdate(updated) }
                if !changes.removedIdentifiers.isEmpty {
                    observer.didDeleteItems(withIdentifiers: changes.removedIdentifiers.map {
                        NSFileProviderItemIdentifier($0.uuidString)
                    })
                }
                observer.finishEnumeratingChanges(upTo: Self.syncAnchor(anchor),
                                                  moreComing: false)
            case .failure(let error):
                observer.finishEnumeratingWithError(FileProviderError.from(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        service.perform { _, index in
            index.anchor
        } completion: { result in
            completionHandler(Self.syncAnchor((try? result.get()) ?? 0))
        }
    }

    private static func syncAnchor(_ value: UInt64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(value)".utf8))
    }
}
