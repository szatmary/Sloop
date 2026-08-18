// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// App/Sloop/Cloudflare/KeychainAccessTokenStore.swift
import Foundation
import SloopKit
#if canImport(Security)
import Security

/// Keychain-backed `AccessTokenStore`. One generic-password item per
/// Access-protected hostname, holding the raw `CF_Authorization` JWT.
///
/// Tokens never touch `HostStore`'s plain-JSON file — only the keychain.
///
/// The lock is what makes this a valid `AccessTokenStore` (see that
/// protocol's concurrency contract). `SecItem*` calls are individually safe
/// to make from any thread, but `setRawToken` is a check-then-act pair of
/// them — copy, then update or add — and the store is written from the main
/// actor and from an SSH worker thread at the same time. Two racing writers
/// can both see "no item", both add, and leave a duplicate the reads then
/// pick between arbitrarily.
final class KeychainAccessTokenStore: AccessTokenStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    init(service: String = "org.szatmary.sloop.access-tokens") {
        self.service = service
    }

    func rawToken(for hostname: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery(for: hostname)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setRawToken(_ raw: String, for hostname: String) throws {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery(for: hostname) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(for hostname: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Normalized so the same host always maps to the same keychain
            // item regardless of how its hostname was typed or imported —
            // see `normalizedAccessHostname`.
            kSecAttrAccount as String: normalizedAccessHostname(hostname),
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "keychain error \(status)"])
    }
}
#endif
