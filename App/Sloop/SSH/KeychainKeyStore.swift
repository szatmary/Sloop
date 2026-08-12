import Foundation
import SloopKit
#if canImport(Security)
import Security

/// Keychain-backed `KeyStore`. One generic-password item per key, account =
/// key name, holding the JSON-encoded `NamedKey`. Items are synchronizable
/// (iCloud Keychain, end-to-end encrypted) and live in the shared access
/// group so Sloop on every device — and the embedded import CLI — see the
/// same library.
///
/// Requires the keychain-access-groups entitlement (Sloop.entitlements);
/// unsigned builds get descriptive errors from set/remove, never silence.
final class KeychainKeyStore: KeyStore {
    static let sharedAccessGroup = "KR5WZAG3UE.org.szatmary.sloop.shared"

    private let service: String
    private let accessGroup: String?

    init(service: String = "org.szatmary.sloop.keys",
         accessGroup: String? = KeychainKeyStore.sharedAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func keys() -> [NamedKey] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Data] else { return [] }
        return items
            .compactMap { try? JSONDecoder().decode(NamedKey.self, from: $0) }
            .sorted { $0.name < $1.name }
    }

    func key(named name: String) -> NamedKey? {
        var query = baseQuery(account: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(NamedKey.self, from: data)
    }

    func setKey(_ key: NamedKey) throws {
        let data = try JSONEncoder().encode(key)
        let query = baseQuery(account: key.name)

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw keychainError(update, "updating key '\(key.name)'") }
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            // AfterFirstUnlock, NOT ...ThisDeviceOnly: device-only items are
            // excluded from iCloud Keychain sync.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            insert[kSecAttrSynchronizable as String] = true
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else { throw keychainError(add, "adding key '\(key.name)'") }
        }
    }

    func removeKey(named name: String) throws {
        let status = SecItemDelete(baseQuery(account: name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, "removing key '\(name)'")
        }
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Matches both synchronizable and (stray) local items so reads,
            // updates, and deletes all see the same set.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        // The iOS-style keychain; the legacy file keychain has no access
        // groups and no sync.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    private func keychainError(_ status: OSStatus, _ doing: String) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey:
                                    "Keychain error \(doing): \(message). " +
                                    "Shared-keychain access requires a signed build (see SIGNING.md)."])
    }
}
#endif
