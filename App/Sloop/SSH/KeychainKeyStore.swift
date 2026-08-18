// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

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
    // Team prefix is hardcoded rather than `$(AppIdentifierPrefix)` because
    // this string is also the CLI's (KeyCLI.swift) and any future non-app
    // caller's contract for which access group to open — a build variable
    // only resolves inside Xcode's entitlements processing. It MUST match
    // the literal prefix baked into App/Sloop/Sloop.entitlements
    // (`$(AppIdentifierPrefix)org.szatmary.sloop.shared`, which Xcode
    // resolves to this same value for the `KR5WZAG3UE` team) — if you ever
    // sign with a different team, update both places together.
    static let sharedAccessGroup = "KR5WZAG3UE.org.szatmary.sloop.shared"

    private let service: String
    private let accessGroup: String?

    init(service: String = "org.szatmary.sloop.keys",
         accessGroup: String? = KeychainKeyStore.sharedAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func keys() throws -> [NamedKey] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw keychainError(status, "reading the key library")
        }
        guard let items = result as? [Data] else {
            throw keychainError(errSecInternalError, "reading the key library")
        }
        // A stored key that won't decode is a real fault, not an absent key.
        // Dropping it silently is how a key appears to vanish from the library.
        return try items
            .map { try JSONDecoder().decode(NamedKey.self, from: $0) }
            .sorted { $0.name < $1.name }
    }

    func key(named name: String) throws -> NamedKey? {
        var query = baseQuery(account: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw keychainError(status, "reading key '\(name)'")
        }
        guard let data = item as? Data else {
            throw keychainError(errSecInternalError, "reading key '\(name)'")
        }
        return try JSONDecoder().decode(NamedKey.self, from: data)
    }

    func setKey(_ key: NamedKey) throws {
        let data = try JSONEncoder().encode(key)
        let query = baseQuery(account: key.name)

        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        guard existing == errSecSuccess || existing == errSecItemNotFound else {
            throw keychainError(existing, "checking for an existing key '\(key.name)'")
        }
        if existing == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw keychainError(update, "updating key '\(key.name)'") }
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            // WhenUnlocked, and NOT ...ThisDeviceOnly (device-only items are
            // excluded from iCloud Keychain sync). AfterFirstUnlock would also
            // sync, but it leaves the private key and its passphrase
            // decryptable on a locked-but-booted device — the entire physical
            // extraction window — to buy background access Sloop never needs:
            // keys are read when a human taps Connect, which requires an
            // unlocked device by definition.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
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
        // errSecMissingEntitlement here almost always means one of two
        // things, neither of which is "needs any signed build" — a build
        // signed by the wrong team (one other than KR5WZAG3UE, the team
        // prefix baked into sharedAccessGroup) hits this same error just as
        // an entirely unsigned one does.
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey:
                                    "Keychain error \(doing): \(message). Likely cause: this " +
                                    "build either isn't signed with an entitlement granting the " +
                                    "'\(accessGroup ?? "(none)")' keychain-access-group, or it's " +
                                    "signed with a different Apple Developer team than the one " +
                                    "baked into that access-group's prefix (KR5WZAG3UE). See " +
                                    "Docs/SIGNING.md."])
    }
}
#endif
