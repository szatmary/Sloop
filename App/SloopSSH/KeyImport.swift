// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if canImport(CSSH)
import Foundation
import SloopKit

/// Everything that can stop a key from entering the library, phrased once.
///
/// The phrasing lives here rather than at each call site because there are four
/// call sites — the `sloop` CLI, the host editor's paste field, an SFTP pull
/// and a file picker — and a user who hits the same problem two different ways
/// should not get two different explanations of it.
public enum KeyImportError: LocalizedError, Equatable {
    case rejected(PrivateKeyMaterial.Rejection)
    case needsPassphrase
    case wrongPassphraseOrUnreadable
    case nameAlreadyInLibrary(String)
    case libraryUnavailable

    public var errorDescription: String? {
        switch self {
        case .rejected(.empty):
            return "There's nothing in that file."
        case .rejected(.notText):
            return "That's a binary file, not a private key."
        case .rejected(.publicKey):
            return "That's a public key — the '.pub' half. Sloop needs the private key: "
                 + "the same filename without the '.pub'."
        case .rejected(.knownHosts):
            return "That's a known_hosts file, which lists other machines' keys rather "
                 + "than one of yours."
        case .rejected(.noPEMEnvelope):
            return "That doesn't look like a private key — there's no BEGIN line in it."
        case .rejected(.truncated):
            return "This key is cut off: it has a BEGIN line but no matching END line. "
                 + "Copy the whole file, including its last line."
        case .needsPassphrase:
            return "This key couldn't be unlocked. If it has a passphrase, enter it — "
                 + "a key that can't be unlocked is never offered to the server."
        case .wrongPassphraseOrUnreadable:
            return "That passphrase didn't unlock the key. Either it's wrong, or the "
                 + "key itself is damaged."
        case .nameAlreadyInLibrary(let name):
            return "A key named '\(name)' is already in your library. The library syncs "
                 + "to all your devices, so Sloop won't replace it — choose another name."
        case .libraryUnavailable:
            return "Sloop's SSH library couldn't start, so the key couldn't be checked."
        }
    }
}

/// The one way a private key enters the library.
///
/// Classify (`PrivateKeyMaterial`), then verify by parsing (`KeyValidator`),
/// then store. Nothing here guesses: a key that will not authenticate is
/// refused at the moment it is offered, with a reason, rather than being stored
/// and failing hours later at connect time as an authentication error.
///
/// Design: `Docs/superpowers/specs/2026-08-19-key-import-design.md`.
public enum KeyImport {

    /// Validates without touching any store. Returns the key that *would* be
    /// stored, including the public key derived during validation.
    public static func prepare(_ data: Data,
                               name: String,
                               passphrase: String?) -> Result<NamedKey, KeyImportError> {
        let recognized: PrivateKeyMaterial.Recognized
        switch PrivateKeyMaterial.recognize(data) {
        case .success(let r): recognized = r
        case .failure(let r): return .failure(.rejected(r))
        }

        switch KeyValidator.validate(pem: recognized.pem, passphrase: passphrase, name: name) {
        case .success(let validated):
            return .success(NamedKey(name: name,
                                     privateKeyPEM: recognized.pem,
                                     publicKey: validated.publicKeyLine,
                                     passphrase: passphrase?.isEmpty == false ? passphrase : nil))
        case .failure(.needsPassphrase):
            return .failure(.needsPassphrase)
        case .failure(.wrongPassphraseOrUnreadable):
            return .failure(.wrongPassphraseOrUnreadable)
        case .failure(.libraryUnavailable):
            return .failure(.libraryUnavailable)
        }
    }

    /// Stores a key that `prepare` already validated.
    ///
    /// Separate from `prepare` for callers that must resolve a passphrase
    /// interactively — they validate, discover the key needs one, ask, and
    /// validate again, and should not then pay for a third parse.
    ///
    /// - Parameter force: overwrite an existing entry of the same name. Off by
    ///   default and deliberately awkward to reach: the library rides iCloud
    ///   Keychain to every device, so replacing an entry destroys key material
    ///   on machines that are not present to object.
    public static func store(_ key: NamedKey,
                             into store: KeyStore,
                             force: Bool = false) throws {
        if !force, try store.key(named: key.name) != nil {
            throw KeyImportError.nameAlreadyInLibrary(key.name)
        }
        try store.setKey(key)
    }

    /// Validates and stores in one step, for callers that already hold the
    /// passphrase (or know there isn't one).
    @discardableResult
    public static func importKey(_ data: Data,
                                 name: String,
                                 passphrase: String?,
                                 into keyStore: KeyStore,
                                 force: Bool = false) throws -> NamedKey {
        let key = try prepare(data, name: name, passphrase: passphrase).get()
        try store(key, into: keyStore, force: force)
        return key
    }
}
#endif
