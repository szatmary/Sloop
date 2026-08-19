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
/// **Everything here splits on UTF-8 bytes, not `Character`s.** A remote path is
/// a byte string whose only structural byte is `0x2F`; Swift's `Character` is a
/// grapheme cluster, and `/` followed by a combining mark is *one* cluster. So
/// `lastIndex(of: "/")` cannot find the separator in `/a/<combining>b`, while a
/// byte split can — and the two disagreeing produced a `name` containing a
/// slash and a `parent` pointing at the wrong directory, for an item the server
/// was perfectly happy with. String indices also count graphemes, so any
/// `dropFirst(n)` derived from a byte length would slice in the wrong place.
///
/// Every path this produces is absolute, separator-collapsed, and free of `.`
/// and `..` segments, so two spellings of one location compare equal. That
/// matters more than tidiness: `SFTPItemIndex` keys items by path, and the same
/// directory arriving as `/a/b` and `/a//b/` would otherwise mint two
/// identifiers for one item and desynchronize the replica.
public enum RemotePath {
    public static let root = "/"

    private static let separator = UInt8(ascii: "/")
    private static let dot: [UInt8] = [UInt8(ascii: ".")]
    private static let dotDot: [UInt8] = [UInt8(ascii: "."), UInt8(ascii: ".")]

    /// An absolute, canonical form of `path`.
    ///
    /// `..` at the root is dropped rather than escaping it. A server resolves
    /// `/..` to `/`, so producing anything else here would mean the index and
    /// the server disagreed about what a path names — and the disagreement
    /// would surface as items that vanish on refresh rather than as an error.
    public static func normalize(_ path: String) -> String {
        var resolved: [[UInt8]] = []
        for segment in Array(path.utf8).split(separator: separator,
                                              omittingEmptySubsequences: true) {
            if segment.elementsEqual(dot) { continue }
            if segment.elementsEqual(dotDot) { _ = resolved.popLast(); continue }
            resolved.append(Array(segment))
        }
        return assemble(resolved)
    }

    /// `directory` with `name` appended as a single further segment.
    ///
    /// `name` is a directory entry, never a path: any `/` in it is the server's
    /// byte, not a separator we invented, and `normalize` collapsing it would
    /// silently retarget the operation at a different directory. Callers pass
    /// names straight from `list(_:)`, so this stays a pure append — see
    /// `isValidName` for the check that keeps a name supplied from elsewhere
    /// from abusing it.
    public static func join(_ directory: String, _ name: String) -> String {
        let base = normalize(directory)
        return base == root ? root + name : base + "/" + name
    }

    /// Whether `name` is usable as a single path segment.
    ///
    /// A name that contains a separator, or is `.`/`..`, would make `join`
    /// produce a path outside the directory it was given. Names from `list(_:)`
    /// cannot be any of those — the server splits on the same byte — but names
    /// arriving from the File Provider system are supplied by other software,
    /// and this is where that assumption stops being free.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "." && name != ".."
            && !name.utf8.contains(separator)
            && !name.utf8.contains(0)
    }

    /// The containing directory. Root's parent is root.
    public static func parent(_ path: String) -> String {
        var segments = self.segments(of: normalize(path))
        guard !segments.isEmpty else { return root }
        segments.removeLast()
        return assemble(segments)
    }

    /// The final segment. Root's name is root — it has no other spelling, and
    /// an empty string here would render as a nameless row in Files.app.
    public static func name(_ path: String) -> String {
        guard let last = segments(of: normalize(path)).last else { return root }
        return String(decoding: last, as: UTF8.self)
    }

    /// Whether `path` lies strictly beneath `directory`.
    ///
    /// The segment boundary is the whole point: a bare prefix test claims
    /// `/a/bc` as a child of `/a/b`, which during a directory rename would
    /// rewrite the path of an unrelated sibling and hand Files.app an item
    /// pointing at a file that does not exist.
    public static func isDescendant(_ path: String, of directory: String) -> Bool {
        let child = segments(of: normalize(path))
        let parent = segments(of: normalize(directory))
        guard child.count > parent.count else { return false }
        return zip(parent, child).allSatisfy { $0.elementsEqual($1) }
    }

    /// `path` with the `from` prefix replaced by `to`, or nil when `path` is
    /// neither `from` itself nor anything beneath it. Directory renames walk
    /// the index with this.
    public static func reparent(_ path: String, from: String, to: String) -> String? {
        let subject = segments(of: normalize(path))
        let source = segments(of: normalize(from))
        guard subject.count >= source.count,
              zip(source, subject).allSatisfy({ $0.elementsEqual($1) }) else { return nil }
        return assemble(segments(of: normalize(to)) + subject.dropFirst(source.count))
    }

    // MARK: - Bytes

    private static func segments(of normalized: String) -> [[UInt8]] {
        Array(normalized.utf8)
            .split(separator: separator, omittingEmptySubsequences: true)
            .map(Array.init)
    }

    private static func assemble(_ segments: [[UInt8]]) -> String {
        guard !segments.isEmpty else { return root }
        var bytes: [UInt8] = []
        for segment in segments {
            bytes.append(separator)
            bytes.append(contentsOf: segment)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
