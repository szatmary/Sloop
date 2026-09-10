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

        // The host is gone from the list, so the location goes with it. The
        // default `.removeAll` is right here: the user deleted the host, and
        // leaving a folder of files that can never sync anywhere would be its
        // own confusion.
        for domain in existing where wanted[domain.identifier] == nil {
            try await NSFileProviderManager.remove(domain)
        }
        for (identifier, host) in wanted {
            if let current = existing.first(where: { $0.identifier == identifier }) {
                // The alias is the location's name in Files. Re-adding under a
                // new display name is the only way to change it.
                guard current.displayName != host.alias else { continue }
                // `.preserveDirtyUserData`, because this is a rename and not a
                // deletion. Plain `remove` defaults to `.removeAll`: a file
                // edited offline in Files, on a host whose alias the user then
                // corrected a typo in, was gone — the edit discarded by a
                // rename that had nothing to do with it.
                try await NSFileProviderManager.remove(current,
                                                       mode: .preserveDirtyUserData)
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

    /// A URL that opens Files.app at this host's folder, or nil when there is
    /// nowhere to send it.
    ///
    /// `getUserVisibleURL` returns the real on-disk location of the domain's
    /// root, somewhere under the system's file-provider storage. That path is
    /// not openable as a `file://` URL — nothing will handle it — but Files.app
    /// registers `shareddocuments://`, and the same path under that scheme
    /// opens the folder in place. Swapping the scheme is the whole trick.
    ///
    /// Nil rather than a thrown error: every caller's response is to not offer
    /// the button, and a host whose domain has not been registered yet is an
    /// ordinary state, not a fault.
    static func userVisibleURL(for host: SSHHost) async -> URL? {
        #if os(iOS) && canImport(FileProvider) && canImport(CSSH)
        let identifier = NSFileProviderDomainIdentifier(host.id.uuidString)
        guard let domain = try? await NSFileProviderManager.domains()
            .first(where: { $0.identifier == identifier }),
              let manager = NSFileProviderManager(for: domain),
              let visible = try? await manager.getUserVisibleURL(for: .rootContainer),
              var components = URLComponents(url: visible, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "shareddocuments"
        return components.url
        #else
        // shareddocuments:// is an iOS scheme. On macOS the equivalent is
        // revealing the folder in Finder, which is a different affordance than
        // the one this exists to provide, so it is left unbuilt rather than
        // approximated.
        return nil
        #endif
    }
}
