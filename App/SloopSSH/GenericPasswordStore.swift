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
    /// The access group per-host credentials and Cloudflare Access tokens live
    /// in, shared by the app and the File Provider extension.
    ///
    /// Deliberately *not* the key library's `…sloop.shared` group. That one is
    /// synchronizable — it rides iCloud Keychain to every device. These items
    /// are `AfterFirstUnlockThisDeviceOnly` and are meant never to leave the
    /// device; folding them into the synced group to solve a process-boundary
    /// problem would change their sync posture as an invisible side effect.
    ///
    /// Hardcoded team prefix for the same reason `KeychainKeyStore` hardcodes
    /// its own: a build variable only resolves inside Xcode's entitlements
    /// processing, and this string is the contract two separate targets agree
    /// on. It MUST match both targets' entitlements files.
    static let sharedAccessGroup = "KR5WZAG3UE.org.szatmary.sloop.fileprovider"

    /// The two services whose items the extension must be able to read. Named
    /// here rather than defaulted at each call site so the stores and the
    /// migration cannot drift apart — a migration that moved a service nobody
    /// reads, or missed one somebody does, fails silently in both directions.
    static let credentialsService = "org.szatmary.sloop.credentials"
    static let accessTokensService = "org.szatmary.sloop.access-tokens"

    private let service: String
    private let accessGroup: String?
    private let lock = NSLock()

    /// - Parameter accessGroup: nil uses the caller's default group — which is
    ///   what these items used before the extension existed, and what
    ///   `migrateToSharedAccessGroup` reads from.
    init(service: String, accessGroup: String? = GenericPasswordStore.sharedAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// The stored bytes, or nil if this account genuinely has no item.
    ///
    /// Throws on every other status rather than answering nil. The refusal that
    /// matters is errSecMissingEntitlement — an unsigned build, or one signed by
    /// a team other than the access group's prefix, is refused the whole
    /// keychain. Reported as nil it reads as "there is nothing stored", which
    /// sent users to re-enter secrets that were already there and turned a
    /// signing problem into an authentication failure at connect time.
    func data(for account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }

        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        guard let data = item as? Data else { throw keychainError(errSecInternalError) }
        return data
    }

    func set(_ data: Data, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }

        let query = baseQuery(for: account)
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        guard existing == errSecSuccess || existing == errSecItemNotFound else {
            throw keychainError(existing)
        }
        if existing == errSecSuccess {
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    /// Copies every item of `service` out of the caller's default access group
    /// and into the shared one, once.
    ///
    /// Before the File Provider extension existed these items had no explicit
    /// group, so they landed in the app's private one — which the extension
    /// cannot read at all. Left unmigrated, every published host would fail to
    /// authenticate with what looks like a wrong password, on a host whose
    /// password is plainly right in the app.
    ///
    /// The old item is deleted only after the new one is written, and an
    /// account that already exists in the shared group is left alone: whatever
    /// is there is at least as new as what is being migrated.
    ///
    /// - Returns: how many items were moved.
    @discardableResult
    static func migrateToSharedAccessGroup(service: String) throws -> Int {
        let legacy = GenericPasswordStore(service: service, accessGroup: nil)
        let shared = GenericPasswordStore(service: service)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecAttrAccessGroup as String] = nil

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey:
                            "couldn't list keychain items for '\(service)' to migrate them "
                            + "into the shared access group (OSStatus \(status))"])
        }

        var moved = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            if try shared.data(for: account) != nil { continue }
            guard let data = try legacy.data(for: account) else { continue }
            try shared.set(data, for: account)
            try legacy.remove(for: account)
            moved += 1
        }
        return moved
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey:
                                    "keychain error \(status) for service '\(service)': \(message)"])
    }
}
#endif
