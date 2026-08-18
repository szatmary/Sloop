// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit
#if canImport(FileProvider)
import FileProvider
#endif

/// Publishes hosts to Files.app, and stops publishing them.
///
/// A `NSFileProviderDomain` is a location the system may enumerate on its own
/// schedule, so this reconciles against `showsInFiles` rather than adding
/// domains eagerly: publishing every saved host would have Files.app dialing
/// servers the user never asked it to, waking tunnels and spending battery for
/// hosts that were only ever meant for a terminal.
///
/// The domain identifier is the host's UUID — the extension parses it straight
/// back into a host lookup. The display name is the alias, so renaming a host
/// in Sloop renames its location in Files.
enum FilesDomainRegistrar {
    /// Whether this build can publish anything at all. The extension only
    /// exists in the SSH variant and up; without libssh2 it could not connect,
    /// and a permanently broken location in Files.app is worse than no
    /// location.
    static var isAvailable: Bool {
        #if canImport(FileProvider) && canImport(CSSH)
        return true
        #else
        return false
        #endif
    }

    /// Brings the registered domains in line with the host list.
    ///
    /// Reconciles in both directions on purpose. Domains outlive the app — one
    /// whose host was deleted while the app was not running would otherwise
    /// stay in Files.app forever, failing every request with "this host no
    /// longer exists".
    static func reconcile(hosts: [SSHHost]) async throws {
        #if canImport(FileProvider) && canImport(CSSH)
        let wanted = Dictionary(
            uniqueKeysWithValues: hosts.filter(\.showsInFiles).map {
                (NSFileProviderDomainIdentifier($0.id.uuidString), $0)
            })
        let existing = try await NSFileProviderManager.domains()

        for domain in existing where wanted[domain.identifier] == nil {
            try await NSFileProviderManager.remove(domain)
        }
        for (identifier, host) in wanted {
            if let current = existing.first(where: { $0.identifier == identifier }) {
                // The alias is the location's name in Files. Re-adding under a
                // new display name is the only way to change it.
                guard current.displayName != host.alias else { continue }
                try await NSFileProviderManager.remove(current)
            }
            // The two-argument initializer is the replicated one. Its
            // `pathRelativeToDocumentStorage` sibling belongs to the older
            // non-replicated API and does not exist on macOS at all.
            try await NSFileProviderManager.add(
                NSFileProviderDomain(identifier: identifier, displayName: host.alias))
        }
        #endif
    }

    /// Tells the system a `notAuthenticated` failure has been dealt with, so
    /// Files.app clears the banner instead of making the user go and poke the
    /// folder again.
    ///
    /// Called after the app fixes the thing the extension could not: a host key
    /// trusted, a Cloudflare Access login completed, a credential entered, a
    /// tailnet device authorized.
    static func signalErrorResolved(for host: SSHHost) async {
        #if canImport(FileProvider) && canImport(CSSH)
        let identifier = NSFileProviderDomainIdentifier(host.id.uuidString)
        guard let domain = try? await NSFileProviderManager.domains()
            .first(where: { $0.identifier == identifier }),
              let manager = NSFileProviderManager(for: domain) else { return }
        try? await manager.signalErrorResolved(
            NSFileProviderError(.notAuthenticated))
        #endif
    }
}
