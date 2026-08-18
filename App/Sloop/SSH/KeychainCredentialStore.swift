// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import SloopKit
#if canImport(Security)

/// Keychain-backed `CredentialStore`. One generic-password item per host,
/// keyed by the host's UUID, holding the JSON-encoded `Credential`.
///
/// Secrets never touch `HostStore`'s plain-JSON file — only the keychain.
final class KeychainCredentialStore: CredentialStore {
    private let items: GenericPasswordStore

    init(service: String = "org.szatmary.sloop.credentials") {
        items = GenericPasswordStore(service: service)
    }

    func credential(for hostID: UUID) -> Credential? {
        guard let data = items.data(for: hostID.uuidString) else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }

    func setCredential(_ credential: Credential, for hostID: UUID) throws {
        try items.set(try JSONEncoder().encode(credential), for: hostID.uuidString)
    }

    func removeCredential(for hostID: UUID) throws {
        try items.remove(for: hostID.uuidString)
    }
}
#endif
