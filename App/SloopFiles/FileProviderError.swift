// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation
import FileProvider
import SloopKit
import SloopSSH

/// Turns Sloop's typed errors into ones the system acts on.
///
/// This is the whole reason `SFTPError` stays a type instead of a string. The
/// system does not merely display these — it *behaves* differently:
/// `NSFileProviderError.notAuthenticated` puts a sign-in affordance on the
/// domain and stops retrying until the app signals the error resolved; `ENOENT`
/// makes it drop the item from the replica; `EACCES` becomes a permissions
/// complaint the user can act on. Collapsing them all into one opaque failure —
/// the mistake `ConnectionState` still makes one layer up, and which
/// `Docs/ROADMAP.md` carries as an open item — would leave the user with a
/// spinner and no next step.
enum FileProviderError {
    static func from(_ error: Error) -> NSError {
        switch error {
        case let error as SFTPError:
            return fileProvider(error)

        // Nothing here can be fixed by retrying, and every case names the one
        // action that fixes it: go to the app. `notAuthenticated` is what makes
        // Files.app say so rather than silently spinning.
        case let error as SFTPClientFactory.Unavailable:
            return notAuthenticated(error)
        case let error as SFTPDomainService.ServiceError:
            switch error {
            case .noSuchHost, .notPublished, .noCredential:
                return notAuthenticated(error)
            case .unknownIdentifier:
                return NSError(domain: NSFileProviderErrorDomain,
                               code: NSFileProviderError.noSuchItem.rawValue,
                               userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
            }
        case let error as SloopStorage.StorageError:
            return notAuthenticated(error)

        // A refused host key is the case this whole design turns on. The
        // extension cannot run trust-on-first-use, so an unknown or changed key
        // arrives here — and must arrive as "go and look at this in Sloop",
        // never as a transient failure the system will quietly retry forever.
        case let error as SSHError:
            return notAuthenticated(error)

        default:
            return error as NSError
        }
    }

    private static func notAuthenticated(_ error: Error) -> NSError {
        NSError(domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.notAuthenticated.rawValue,
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription,
                           NSUnderlyingErrorKey: error as NSError])
    }

    /// Maps a server refusal onto the only two domains the system accepts.
    ///
    /// `NSFileProviderReplicatedExtension` is explicit: errors must be in
    /// `NSFileProviderErrorDomain` or `NSCocoaErrorDomain`, and *"any other
    /// error … will be considered to be transient and will cause the
    /// [operation] to be retried."*
    ///
    /// This originally returned `NSPOSIXErrorDomain` with the errno from
    /// `SFTPError.posixCode`, on the belief that the system read those directly.
    /// It does not — POSIX is a third domain, so every one of these was
    /// classified transient. A file deleted on the server was retried forever
    /// instead of leaving the replica, and a permissions refusal never reached
    /// the user at all. The errno mapping still exists and is still tested; it
    /// is simply not what this boundary speaks.
    private static func fileProvider(_ error: SFTPError) -> NSError {
        let info: [String: Any] = [NSLocalizedDescriptionKey: error.localizedDescription,
                                   NSUnderlyingErrorKey: error as NSError]
        switch error {
        case .noSuchFile:
            // The system's cue to drop the item from the replica rather than
            // keep asking for it.
            return NSError(domain: NSFileProviderErrorDomain,
                           code: NSFileProviderError.noSuchItem.rawValue, userInfo: info)
        case .alreadyExists:
            return NSError(domain: NSFileProviderErrorDomain,
                           code: NSFileProviderError.filenameCollision.rawValue, userInfo: info)
        case .directoryNotEmpty:
            // Required by the deleteItem contract so the system restores the
            // directory it had already removed from disk.
            return NSError(domain: NSFileProviderErrorDomain,
                           code: NSFileProviderError.directoryNotEmpty.rawValue, userInfo: info)
        case .permissionDenied:
            return NSError(domain: NSCocoaErrorDomain,
                           code: NSFileReadNoPermissionError, userInfo: info)
        case .noSpace, .quotaExceeded:
            return NSError(domain: NSCocoaErrorDomain,
                           code: NSFileWriteOutOfSpaceError, userInfo: info)
        case .isADirectory, .notADirectory, .unsupported:
            return NSError(domain: NSCocoaErrorDomain,
                           code: NSFeatureUnsupportedError, userInfo: info)
        case .connectionLost, .protocolFailure:
            // The one class that genuinely *is* transient: retrying after a
            // dropped link is the right behavior, and the client now redials.
            return NSError(domain: NSCocoaErrorDomain,
                           code: NSXPCConnectionReplyInvalid, userInfo: info)
        }
    }
}
