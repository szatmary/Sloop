// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Parses an OpenSSH `~/.ssh/config` into importable `SSHHost` entries.
///
/// Deliberately small: it reads the connection-shaping keywords Sloop models
/// today — `Host`, `HostName`, `User`, `Port` — plus one directive of its own
/// (`# SloopConnectionMethod`, which carries `SSHHost.connectionMethod`
/// through an export), and ignores everything else.
/// Secrets are never imported (the config only references key *paths*, and the
/// real material lives elsewhere), so every imported host comes in with
/// password auth; the user sets credentials afterward in the editor.
///
/// Pure value-in/value-out, so it's unit-tested in SloopKit. It also formats
/// hosts back out (`format`), the inverse of `parse`, so a Sloop host list can
/// be exported as an OpenSSH config.
public enum SSHConfigParser {

    /// The keyword carrying `SSHHost.connectionMethod` through an export.
    ///
    /// It rides in a `#` comment because it is not an OpenSSH keyword: a real
    /// `ssh` would reject an unknown one, and an exported config has to stay a
    /// usable `ssh_config`. The value is the `ConnectionMethod` raw value
    /// verbatim, so this and the JSON host file agree on the spelling by
    /// construction rather than by a mapping table that could drift.
    private static let connectionMethodDirective = "SloopConnectionMethod"

    /// Render hosts as OpenSSH config text — the inverse of `parse`. Emits
    /// `HostName` only when it differs from the alias (so `parse` reconstructs
    /// it via its alias default), `User` when set, `Port` when non-default,
    /// and the `SloopConnectionMethod` directive for anything but `.direct`.
    /// Secrets are never written (the model doesn't hold them here).
    ///
    /// Note: OpenSSH `Host` names are whitespace-separated tokens, so an alias
    /// containing spaces won't round-trip; such aliases are emitted verbatim but
    /// re-import to just their first token.
    public static func format(_ hosts: [SSHHost]) -> String {
        var lines: [String] = []
        for host in hosts {
            lines.append("Host \(host.alias)")
            if !host.hostname.isEmpty, host.hostname != host.alias {
                lines.append("    HostName \(host.hostname)")
            }
            if !host.username.isEmpty {
                lines.append("    User \(host.username)")
            }
            if host.port != 22 {
                lines.append("    Port \(host.port)")
            }
            if host.connectionMethod != .direct {
                lines.append("    # \(connectionMethodDirective) \(host.connectionMethod.rawValue)")
            }
            lines.append("")   // blank line between blocks
        }
        return lines.joined(separator: "\n")
    }

    /// Parse config text into hosts, in file order. Wildcard `Host` patterns
    /// (`*`, `?`) are defaults, not real hosts, so they're skipped.
    public static func parse(_ text: String) -> [SSHHost] {
        var hosts: [SSHHost] = []

        // Accumulates the fields of the current `Host` block until the next
        // `Host` line (or end of file) flushes it.
        var alias: String?
        var hostname: String?
        var user: String?
        var port: Int?
        var connectionMethod: ConnectionMethod?
        /// Set when the block names a connection method this build doesn't
        /// know, which discards the block — see `flush`.
        var unknownConnectionMethod: String?

        func flush() {
            defer {
                alias = nil; hostname = nil; user = nil; port = nil
                connectionMethod = nil; unknownConnectionMethod = nil
            }
            guard let alias, !isPattern(alias) else { return }
            // Fail closed on a method we can't honour. Importing it as
            // `.direct` would send this host's username, password, or private
            // key straight to whatever answers on port 22 at a hostname that
            // was only ever meant to be reached through a tunnel — the exact
            // leak `SSHHost`'s decoder refuses for the same reason (a saved
            // host with an unknown method fails to decode rather than
            // downgrading). Dropping the block loses an import; downgrading it
            // loses the credential.
            guard unknownConnectionMethod == nil else { return }
            hosts.append(SSHHost(alias: alias,
                                 hostname: (hostname?.isEmpty == false) ? hostname! : alias,
                                 port: port ?? 22,
                                 username: user ?? "",
                                 auth: .password,
                                 connectionMethod: connectionMethod ?? .direct))
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Comments are ignored, except for Sloop's own directives, which
            // live in them so the exported file stays a valid ssh_config.
            if line.hasPrefix("#") {
                if let raw = directiveValue(line, named: connectionMethodDirective) {
                    if let method = ConnectionMethod(rawValue: raw) {
                        connectionMethod = method
                    } else {
                        unknownConnectionMethod = raw
                    }
                }
                continue
            }

            let (keyword, value) = splitKeyValue(line)
            guard !value.isEmpty else { continue }

            switch keyword.lowercased() {
            case "host":
                flush()
                // A Host line may list several patterns; the first token names
                // the block.
                alias = value.split(separator: " ").first.map(String.init) ?? value
            case "hostname":
                hostname = value
            case "user":
                user = value
            case "port":
                port = Int(value)
            default:
                break
            }
        }
        flush()
        return hosts
    }

    /// The value of a Sloop directive carried in a comment line, or nil when
    /// this comment isn't that directive. Matched case-insensitively, like
    /// every other keyword here, and tolerant of `#Keyword`, `# Keyword`, and
    /// `## Keyword` alike — a value-less directive reads as "not present"
    /// rather than as an empty method name.
    private static func directiveValue(_ line: String, named name: String) -> String? {
        let body = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        let (keyword, value) = splitKeyValue(body)
        guard keyword.lowercased() == name.lowercased(), !value.isEmpty else { return nil }
        return value
    }

    /// Split a config line into keyword and value. OpenSSH accepts either
    /// `Keyword value` or `Keyword=value`, with optional surrounding spaces.
    private static func splitKeyValue(_ line: String) -> (keyword: String, value: String) {
        // Find the first separator: whitespace or '='.
        guard let sepIndex = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line, "")
        }
        let keyword = String(line[line.startIndex..<sepIndex])
        var value = String(line[line.index(after: sepIndex)...])
        // A `=` separator may still have spaces around it; trim, then also drop
        // a leading `=` in the `Keyword = value` (space-equals-space) form.
        value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("=") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return (keyword, value)
    }

    private static func isPattern(_ alias: String) -> Bool {
        alias.contains("*") || alias.contains("?")
    }
}
