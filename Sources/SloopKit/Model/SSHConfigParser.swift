import Foundation

/// Parses an OpenSSH `~/.ssh/config` into importable `SSHHost` entries.
///
/// Deliberately small: it reads the connection-shaping keywords Sloop models
/// today — `Host`, `HostName`, `User`, `Port` — and ignores everything else.
/// Secrets are never imported (the config only references key *paths*, and the
/// real material lives elsewhere), so every imported host comes in with
/// password auth; the user sets credentials afterward in the editor.
///
/// Pure value-in/value-out, so it's unit-tested in SloopKit. It also formats
/// hosts back out (`format`), the inverse of `parse`, so a Sloop host list can
/// be exported as an OpenSSH config.
public enum SSHConfigParser {

    /// Render hosts as OpenSSH config text — the inverse of `parse`. Emits
    /// `HostName` only when it differs from the alias (so `parse` reconstructs
    /// it via its alias default), `User` when set, and `Port` when non-default.
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

        func flush() {
            defer { alias = nil; hostname = nil; user = nil; port = nil }
            guard let alias, !isPattern(alias) else { return }
            hosts.append(SSHHost(alias: alias,
                                 hostname: (hostname?.isEmpty == false) ? hostname! : alias,
                                 port: port ?? 22,
                                 username: user ?? "",
                                 auth: .password))
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

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
