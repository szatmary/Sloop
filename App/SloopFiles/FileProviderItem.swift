// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import FileProvider
import UniformTypeIdentifiers
import SloopKit

/// One remote entry, as the system sees it.
///
/// The identifier is *not* derived from the path. `NSFileProviderItemIdentifier`
/// must not change when an item is renamed or moved, and a path does; the
/// stable id comes from `SFTPItemIndex`, which rewrites the path underneath it.
/// Deriving it here from the path would be simpler and would corrupt the
/// replica on the first rename.
final class FileProviderItem: NSObject, NSFileProviderItem {
    private let entry: SFTPEntry
    private let identifier: NSFileProviderItemIdentifier
    private let parent: NSFileProviderItemIdentifier

    init(entry: SFTPEntry,
         identifier: NSFileProviderItemIdentifier,
         parent: NSFileProviderItemIdentifier) {
        self.entry = entry
        self.identifier = identifier
        self.parent = parent
    }

    var itemIdentifier: NSFileProviderItemIdentifier { identifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { parent }
    var filename: String { entry.name }

    var contentType: UTType {
        switch entry.kind {
        case .directory:
            return .folder
        case .file, .symlink, .other:
            // Symlinks are already resolved by `stat`, so a symlink reaching
            // here is one whose target could not be typed. `.data` is the
            // honest answer: openable, no claim about what is inside.
            let ext = (entry.name as NSString).pathExtension
            guard !ext.isEmpty else { return .data }
            return UTType(filenameExtension: ext) ?? .data
        }
    }

    var documentSize: NSNumber? { entry.isDirectory ? nil : NSNumber(value: entry.size) }
    var contentModificationDate: Date? { entry.modified }
    var creationDate: Date? { nil }   // SFTP does not carry one.

    /// Version identity for the replica.
    ///
    /// Content changes when size or mtime does; metadata when the mode does.
    /// Splitting them matters: a `chmod` alone must not make the system believe
    /// the bytes changed and re-download the file.
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: Data("\(entry.size)-\(entry.modified.timeIntervalSince1970)".utf8),
            metadataVersion: Data("\(entry.mode)".utf8))
    }

    /// What the system may offer the user for this item.
    ///
    /// Write permission is read off the remote mode rather than granted
    /// blanket. Offering "rename" on a file in a directory the user cannot
    /// write produces a failure *after* they have typed a new name, which is a
    /// worse experience than the option being absent.
    var capabilities: NSFileProviderItemCapabilities {
        let writable = entry.permissions & 0o200 != 0
        if entry.isDirectory {
            var capabilities: NSFileProviderItemCapabilities = [.allowsContentEnumerating]
            if writable { capabilities.insert([.allowsAddingSubItems, .allowsDeleting,
                                               .allowsRenaming, .allowsReparenting]) }
            return capabilities
        }
        var capabilities: NSFileProviderItemCapabilities = [.allowsReading]
        if writable { capabilities.insert([.allowsWriting, .allowsDeleting,
                                           .allowsRenaming, .allowsReparenting]) }
        return capabilities
    }
}

/// The domain's root. A synthetic container: it has no `SFTPEntry` of its own
/// because the system requires `.rootContainer` to answer with a fixed
/// identifier, and giving it the remote directory's real identity would mean
/// two identifiers for one path.
final class FileProviderRootItem: NSObject, NSFileProviderItem {
    private let name: String

    init(name: String) { self.name = name }

    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { name }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities {
        [.allowsContentEnumerating, .allowsAddingSubItems, .allowsReading]
    }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data("root".utf8),
                                  metadataVersion: Data("root".utf8))
    }
}
