// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
#if canImport(Security)
import Security

/// One generic-password item per account, in one service. The shape both
/// per-host credentials (`KeychainCredentialStore`) and Cloudflare Access
/// tokens (`KeychainAccessTokenStore`) are stored in, factored out of the two
/// near-identical copies that used to hold it: same base query, same
/// copy-then-update-or-add, same error wrapping, differing only in what the
/// account string is and what gets encoded into the value.
///
/// The bytes are opaque here on purpose — a `Codable` payload would push both
/// callers' encoding decisions into this type for no gain, and neither of them
/// wants the other's.
///
/// Access is serialized. The keychain's own calls are individually thread-safe,
/// but `set` is a check-then-act pair of them: two writers racing can both see
/// "no item", both add, and leave a duplicate for the reads to choose between.
/// `AccessTokenStore` requires this of its conformances explicitly — the store
/// is written from the main actor and from SSH worker threads.
final class GenericPasswordStore: @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    init(service: String) {
        self.service = service
    }

    func data(for account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    func set(_ data: Data, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let query = baseQuery(for: account)
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
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

    /// Removing an absent account is not an error.
    func remove(for account: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey:
                                    "keychain error \(status) for service '\(service)': \(message)"])
    }
}
#endif
