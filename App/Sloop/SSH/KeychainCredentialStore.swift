// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit
#if canImport(Security)
import Security

/// Keychain-backed `CredentialStore`. One generic-password item per host,
/// keyed by the host's UUID, holding the JSON-encoded `Credential`.
///
/// Secrets never touch `HostStore`'s plain-JSON file — only the keychain.
final class KeychainCredentialStore: CredentialStore {
    private let items: GenericPasswordStore

    init(service: String = "org.szatmary.sloop.credentials") {
        items = GenericPasswordStore(service: service)
    }

    /// Throws when the keychain refuses the read; nil means this host has no
    /// stored secret. A refused read reported as nil looks exactly like a host
    /// nobody ever typed a password for — see `GenericPasswordStore.data`.
    func credential(for hostID: UUID) throws -> Credential? {
        guard let data = try items.data(for: hostID.uuidString) else { return nil }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    func setCredential(_ credential: Credential, for hostID: UUID) throws {
        try items.set(try JSONEncoder().encode(credential), for: hostID.uuidString)
    }

    func removeCredential(for hostID: UUID) throws {
        try items.remove(for: hostID.uuidString)
    }
}
#endif
