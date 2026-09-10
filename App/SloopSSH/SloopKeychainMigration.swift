// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Moves the secrets the File Provider extension needs into a keychain group it
/// can actually read.
///
/// Before the extension existed, per-host credentials and Cloudflare Access
/// tokens were written with no explicit access group, so they landed in the
/// app's private one. The extension is a different process with a different
/// default group and cannot see them at all. Left unmigrated, every published
/// host fails to authenticate with what looks like a wrong password — on a host
/// whose password is plainly correct in the app, which is close to
/// undiagnosable from the outside.
///
/// Run at launch. It is idempotent and cheap once there is nothing left to move.
public enum SloopKeychainMigration {
    /// - Returns: how many items moved. Zero on every launch after the first.
    @discardableResult
    public static func migrateToSharedAccessGroup() throws -> Int {
        #if canImport(Security)
        // Not `+` across two calls in one expression: if the second throws, the
        // first has still happened, and the count is the only evidence of it.
        var moved = try GenericPasswordStore.migrateToSharedAccessGroup(
            service: GenericPasswordStore.credentialsService)
        moved += try GenericPasswordStore.migrateToSharedAccessGroup(
            service: GenericPasswordStore.accessTokensService)
        return moved
        #else
        return 0
        #endif
    }
}
