// App/Sloop/Cloudflare/KeychainAccessTokenStore.swift
import Foundation
import SloopKit
#if canImport(Security)
import Security

/// Keychain-backed `AccessTokenStore`. One generic-password item per
/// Access-protected hostname, holding the raw `CF_Authorization` JWT.
///
/// Tokens never touch `HostStore`'s plain-JSON file — only the keychain.
final class KeychainAccessTokenStore: AccessTokenStore {
    private let service: String

    init(service: String = "org.szatmary.sloop.access-tokens") {
        self.service = service
    }

    func rawToken(for hostname: String) -> String? {
        var query = baseQuery(for: hostname)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setRawToken(_ raw: String, for hostname: String) throws {
        let data = Data(raw.utf8)
        let query = baseQuery(for: hostname)

        let status = SecItemCopyMatching(query as CFDictionary, nil)
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

    func removeToken(for hostname: String) throws {
        let status = SecItemDelete(baseQuery(for: hostname) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(for hostname: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostname,
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "keychain error \(status)"])
    }
}
#endif
