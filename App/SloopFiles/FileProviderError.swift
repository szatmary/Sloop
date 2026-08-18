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
            return posix(error.posixCode, describing: error)

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

    private static func posix(_ code: Int32, describing error: Error) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: error.localizedDescription,
                           NSUnderlyingErrorKey: error as NSError])
    }
}
