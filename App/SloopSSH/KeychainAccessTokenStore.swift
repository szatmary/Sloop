// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// App/Sloop/Cloudflare/KeychainAccessTokenStore.swift
import Foundation
import SloopKit
#if canImport(Security)

/// Keychain-backed `AccessTokenStore`. One generic-password item per
/// Access-protected hostname, holding the raw `CF_Authorization` JWT.
///
/// Tokens never touch `HostStore`'s plain-JSON file — only the keychain.
///
/// `@unchecked Sendable` is earned by `GenericPasswordStore`, which serializes
/// every access — see the concurrency contract on `AccessTokenStore`.
public final class KeychainAccessTokenStore: AccessTokenStore, @unchecked Sendable {
    private let items: GenericPasswordStore

    public init(service: String = "org.szatmary.sloop.access-tokens") {
        items = GenericPasswordStore(service: service)
    }

    public func rawToken(for hostname: String) throws -> String? {
        guard let data = try items.data(for: account(hostname)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setRawToken(_ raw: String, for hostname: String) throws {
        try items.set(Data(raw.utf8), for: account(hostname))
    }

    public func removeToken(for hostname: String) throws {
        try items.remove(for: account(hostname))
    }

    /// Normalized so the same host always maps to the same keychain item
    /// regardless of how its hostname was typed or imported — see
    /// `normalizedAccessHostname`.
    private func account(_ hostname: String) -> String {
        normalizedAccessHostname(hostname)
    }
}
#endif
