// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if canImport(CSSH)
import Foundation
import CSSH
import SloopKit

/// Decides whether a private key is usable, before it is stored.
///
/// One libssh2 call answers four questions at once: does the PEM parse, does it
/// need a passphrase, is the supplied passphrase right, and what is the
/// corresponding public key. Every import path routes through here, so a key
/// that cannot authenticate is refused at the moment it is offered rather than
/// hours later at connect time, reported as an authentication failure.
///
/// This replaces guessing. `KeyCLI.isEncryptedPEM` used to decide whether to
/// prompt for a passphrase by searching for the literal string `ENCRYPTED` and
/// for `bcrypt` in the base64-decoded body, which missed an OpenSSH-format key
/// using any other KDF: the key imported silently with no passphrase and failed
/// at connect. Attempting the parse is the answer, and it is available.
///
/// Design: `Docs/superpowers/specs/2026-08-19-key-import-design.md`.
public enum KeyValidator {

    public enum Failure: Error, Equatable {
        /// The key did not parse and no passphrase was supplied. Almost always
        /// means it needs one — but a corrupt unencrypted key looks identical
        /// to libssh2, so the caller prompts and finds out.
        case needsPassphrase
        /// The key did not parse with a passphrase supplied: either the
        /// passphrase is wrong or the key is damaged. libssh2 does not
        /// distinguish these, and claiming otherwise would be a guess.
        case wrongPassphraseOrUnreadable
        /// libssh2 itself would not start. Not a property of the key.
        case libraryUnavailable
    }

    public struct Validated: Equatable {
        /// The SSH algorithm name libssh2 derived, e.g. `ssh-ed25519`.
        public let algorithm: String
        /// An OpenSSH `.pub` line: `<algorithm> <base64 blob> <name>`. This is
        /// what `NamedKey.publicKey` stores and what installing a key on a host
        /// appends to `authorized_keys`.
        public let publicKeyLine: String
    }

    /// - Parameter name: used only as the comment field of the returned `.pub`
    ///   line, matching what `AgentSigner` does for identities.
    public static func validate(pem: String,
                                passphrase: String?,
                                name: String) -> Result<Validated, Failure> {
        guard LibSSH2Library.isReady else { return .failure(.libraryUnavailable) }

        // An empty passphrase is no passphrase. This normalization is for the
        // `Failure` this function reports, not for libssh2 — which is handed
        // "" either way. It decides whether a failed parse means "ask for a
        // passphrase" or "that passphrase was wrong".
        let passphrase = (passphrase?.isEmpty == false) ? passphrase : nil

        // A session that is never connected. libssh2 uses it for its allocator
        // and error state, not for I/O, which is what makes offline validation
        // possible at all.
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            return .failure(.libraryUnavailable)
        }
        defer { libssh2_session_free(session) }

        var method: UnsafeMutablePointer<UInt8>?
        var methodLength = 0
        var blob: UnsafeMutablePointer<UInt8>?
        var blobLength = 0

        let rc = pem.withCString { pemPtr in
            withPassphraseCString(passphrase) { passPtr in
                _libssh2_pub_priv_keyfilememory(session,
                                                &method, &methodLength,
                                                &blob, &blobLength,
                                                pemPtr, pem.utf8.count,
                                                passPtr)
            }
        }
        defer {
            if let method { free(method) }
            if let blob { free(blob) }
        }

        guard rc == 0, let method, let blob else {
            return .failure(passphrase == nil ? .needsPassphrase : .wrongPassphraseOrUnreadable)
        }

        let algorithm = String(decoding: UnsafeBufferPointer(start: method, count: methodLength),
                               as: UTF8.self)
        let encoded = Data(UnsafeBufferPointer(start: blob, count: blobLength)).base64EncodedString()
        return .success(Validated(algorithm: algorithm,
                                  publicKeyLine: "\(algorithm) \(encoded) \(name)"))
    }
}

/// Runs `body` with a C string for the passphrase, using the empty string when
/// there is none.
///
/// Never NULL, and the non-optional pointer is the point: NULL does not mean
/// "no passphrase" to OpenSSL. For a legacy `Proc-Type: 4,ENCRYPTED` PEM,
/// `PEM_read_bio_PrivateKey` reaches `PEM_def_callback`, its default UI, which
/// reads a passphrase from stdin with `fgets` — and blocks forever in an app
/// that has no terminal. libssh2 draws no NULL-vs-"" distinction on any path,
/// so the empty string is both safe and accurate.
///
/// Shared by `KeyValidator` and `AgentSigner`.
func withPassphraseCString<T>(_ passphrase: String?,
                              _ body: (UnsafePointer<CChar>) -> T) -> T {
    (passphrase ?? "").withCString(body)
}
#endif
