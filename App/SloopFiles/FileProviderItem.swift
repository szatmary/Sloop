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
    /// Whether the *containing directory* is writable, which is what POSIX
    /// actually consults for rename, delete and move — not the item's own mode.
    /// Nil when it hasn't been looked up, in which case those are offered and
    /// the server has the final say.
    private let parentIsWritable: Bool?

    init(entry: SFTPEntry,
         identifier: NSFileProviderItemIdentifier,
         parent: NSFileProviderItemIdentifier,
         parentIsWritable: Bool? = nil) {
        self.entry = entry
        self.identifier = identifier
        self.parent = parent
        self.parentIsWritable = parentIsWritable
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
        // `entry.contentVersion`, not a second spelling of the same formula:
        // `replaceFile` compares against exactly this value to decide whether
        // the server's copy moved on, and two copies of it would drift into a
        // conflict check that fires on everything or on nothing.
        NSFileProviderItemVersion(contentVersion: entry.contentVersion,
                                  metadataVersion: Data("\(entry.mode)".utf8))
    }

    /// What the system may offer the user for this item.
    ///
    /// Two different permissions, which an earlier version conflated. Reading
    /// and writing an item's *contents* depend on that item's mode; renaming,
    /// deleting and moving it depend on the mode of the directory holding it,
    /// because those operations modify the directory, not the file. Deriving
    /// all four from the item's own write bit got both cases backwards: a
    /// read-only file in a writable home was shown as unrenamable when it is
    /// renamable, and a writable file in a read-only directory was offered a
    /// rename that fails only after the user has typed a new name.
    ///
    /// The owner bit is the best available approximation — SFTP reports a mode
    /// and a uid, but nothing about which of them the connected user is — so
    /// where the answer is unknown the capability is offered and the server
    /// decides. A refusal from the server is a worse experience than a hidden
    /// menu item, but a *hidden* action the user is entitled to is worse still.
    var capabilities: NSFileProviderItemCapabilities {
        let contentsWritable = entry.permissions & 0o200 != 0
        // Unknown means "not looked up", which must not read as "forbidden".
        let inWritableDirectory = parentIsWritable ?? true

        var capabilities: NSFileProviderItemCapabilities = entry.isDirectory
            ? [.allowsContentEnumerating]
            : [.allowsReading]
        if !entry.isDirectory, contentsWritable { capabilities.insert(.allowsWriting) }
        if entry.isDirectory, contentsWritable { capabilities.insert(.allowsAddingSubItems) }
        if inWritableDirectory {
            capabilities.insert([.allowsDeleting, .allowsRenaming, .allowsReparenting])
        }
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
