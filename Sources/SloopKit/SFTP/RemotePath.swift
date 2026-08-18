// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// POSIX path arithmetic for the remote side of an SFTP connection.
///
/// Deliberately *not* `URL` or `NSString.pathComponents`. Those carry Foundation's
/// notions of file URLs, percent-encoding, and (on Darwin) case-insensitivity,
/// none of which describe a remote POSIX server: a remote host may hold `README`
/// and `readme` in one directory, and a name may contain any byte but `/` and
/// NUL — including a `%`, a backslash, or a newline. Every one of those survives
/// this type unchanged, and would not survive a round trip through `URL`.
///
/// Every path this produces is absolute, separator-collapsed, and free of `.`
/// and `..` segments, so two spellings of one location compare equal. That
/// matters more than tidiness: `SFTPItemIndex` keys items by path, and the same
/// directory arriving as `/a/b` and `/a//b/` would otherwise mint two
/// identifiers for one item and desynchronize the replica.
public enum RemotePath {
    public static let root = "/"

    /// An absolute, canonical form of `path`.
    ///
    /// `..` at the root is dropped rather than escaping it. A server resolves
    /// `/..` to `/`, so producing anything else here would mean the index and
    /// the server disagreed about what a path names — and the disagreement
    /// would surface as items that vanish on refresh rather than as an error.
    public static func normalize(_ path: String) -> String {
        var resolved: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch segment {
            case ".": continue
            case "..": _ = resolved.popLast()
            default: resolved.append(segment)
            }
        }
        return resolved.isEmpty ? root : "/" + resolved.joined(separator: "/")
    }

    /// `directory` with `name` appended as a single further segment.
    ///
    /// `name` is a directory entry, never a path: any `/` in it is the server's
    /// byte, not a separator we invented, and `normalize` collapsing it would
    /// silently retarget the operation at a different directory. Callers pass
    /// names straight from `list(_:)`, so this stays a pure append.
    public static func join(_ directory: String, _ name: String) -> String {
        let base = normalize(directory)
        return base == root ? root + name : base + "/" + name
    }

    /// The containing directory. Root's parent is root.
    public static func parent(_ path: String) -> String {
        let normalized = normalize(path)
        guard normalized != root,
              let slash = normalized.lastIndex(of: "/") else { return root }
        let head = normalized[normalized.startIndex..<slash]
        return head.isEmpty ? root : String(head)
    }

    /// The final segment. Root's name is root — it has no other spelling, and
    /// an empty string here would render as a nameless row in Files.app.
    public static func name(_ path: String) -> String {
        let normalized = normalize(path)
        guard normalized != root,
              let slash = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slash)...])
    }

    /// Whether `path` lies strictly beneath `directory`.
    ///
    /// The segment boundary is the whole point: a bare `hasPrefix` claims
    /// `/a/bc` as a child of `/a/b`, which during a directory rename would
    /// rewrite the path of an unrelated sibling and hand Files.app an item
    /// pointing at a file that does not exist.
    public static func isDescendant(_ path: String, of directory: String) -> Bool {
        let path = normalize(path), directory = normalize(directory)
        guard path != directory else { return false }
        return directory == root ? true : path.hasPrefix(directory + "/")
    }

    /// `path` with the `from` prefix replaced by `to`, or nil when `path` is
    /// neither `from` itself nor anything beneath it. Directory renames walk
    /// the index with this.
    public static func reparent(_ path: String, from: String, to: String) -> String? {
        let path = normalize(path), from = normalize(from), to = normalize(to)
        if path == from { return to }
        guard isDescendant(path, of: from) else { return nil }
        let suffix = path.dropFirst(from == root ? 1 : from.count + 1)
        return join(to, String(suffix))
    }
}
