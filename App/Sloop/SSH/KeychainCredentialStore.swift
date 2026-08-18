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
    private let service: String

    init(service: String = "org.szatmary.sloop.credentials") {
        self.service = service
    }

    func credential(for hostID: UUID) throws -> Credential? {
        var query = baseQuery(for: hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let data = item as? Data else { throw keychainError(errSecInternalError) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    func setCredential(_ credential: Credential, for hostID: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(for: hostID)

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
        if status == errSecSuccess {
            let attributes: [String: Any] = [kSecValueData as String: data]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else { throw keychainError(update) }
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else { throw keychainError(add) }
        }
    }

    func removeCredential(for hostID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: hostID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(for hostID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.uuidString,
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: "Keychain error: \(message)"])
    }
}
#endif
