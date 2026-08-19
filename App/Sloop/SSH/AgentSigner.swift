// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

// Signing for a forwarded agent. Compiles only where libssh2 does, like every
// other file in this directory.
#if canImport(CSSH)
import Foundation
import CryptoKit
import CSSH
import SloopKit

/// Turns a signature request into a signature, using libssh2's own crypto.
///
/// Every key type takes the same three steps — parse the private key from
/// memory, hash if the algorithm wants a digest, sign — and produces the same
/// wire shape. See `Docs/superpowers/specs/2026-08-18-agent-forwarding-design.md`
/// for why libssh2's internals rather than CryptoKit or OpenSSL.
final class AgentSigner {
    enum SignError: Error {
        case unsupportedAlgorithm(String)
        /// A bare `ssh-rsa` request. SHA-1; refused on purpose.
        case sha1Refused
        case keyUnreadable(String)
        case signingFailed(Int32)
    }

    private let session: OpaquePointer
    private let keysByName: [String: NamedKey]
    private(set) var identities: [AgentIdentity] = []

    /// Derives an identity per key up front. A key the crypto cannot read is
    /// dropped rather than fatal: it simply is not offered, and the others
    /// still work.
    init(session: OpaquePointer, keys: [NamedKey]) {
        self.session = session
        self.keysByName = Dictionary(uniqueKeysWithValues: keys.map { ($0.name, $0) })
        self.identities = keys.compactMap { Self.identity(session: session, key: $0) }
    }

    func identity(matching blob: [UInt8]) -> AgentIdentity? {
        identities.first { $0.blob == blob }
    }

    // MARK: Identity derivation

    private static func identity(session: OpaquePointer, key: NamedKey) -> AgentIdentity? {
        var method: UnsafeMutablePointer<UInt8>?
        var methodLength = 0
        var blob: UnsafeMutablePointer<UInt8>?
        var blobLength = 0

        let rc = key.privateKeyPEM.withCString { pemPtr in
            withOptionalPassphrase(key.passphrase) { passPtr in
                _libssh2_pub_priv_keyfilememory(session,
                                                &method, &methodLength,
                                                &blob, &blobLength,
                                                pemPtr, key.privateKeyPEM.utf8.count,
                                                passPtr)
            }
        }
        defer {
            if let method { free(method) }
            if let blob { free(blob) }
        }
        guard rc == 0, let method, let blob else { return nil }

        let algorithm = String(decoding: UnsafeBufferPointer(start: method, count: methodLength),
                               as: UTF8.self)
        return AgentIdentity(keyName: key.name,
                             algorithm: algorithm,
                             blob: Array(UnsafeBufferPointer(start: blob, count: blobLength)),
                             comment: key.name)
    }

    // MARK: Signing

    func sign(identity: AgentIdentity,
              data: [UInt8],
              flags: UInt32) throws -> (algorithm: String, signature: [UInt8]) {
        guard let key = keysByName[identity.keyName] else {
            throw SignError.keyUnreadable(identity.keyName)
        }

        switch identity.algorithm {
        case "ssh-ed25519":
            // Ed25519 hashes internally; it signs the message itself.
            return ("ssh-ed25519", try signEd25519(key: key, message: data))

        case "ssh-rsa":
            if flags & AgentSignFlags.rsaSHA2_512 != 0 {
                return ("rsa-sha2-512",
                        try signRSA(key: key, hash: Array(SHA512.hash(data: data))))
            }
            if flags & AgentSignFlags.rsaSHA2_256 != 0 {
                return ("rsa-sha2-256",
                        try signRSA(key: key, hash: Array(SHA256.hash(data: data))))
            }
            throw SignError.sha1Refused

        case "ecdsa-sha2-nistp256":
            return (identity.algorithm,
                    try signECDSA(key: key, hash: Array(SHA256.hash(data: data))))
        case "ecdsa-sha2-nistp384":
            return (identity.algorithm,
                    try signECDSA(key: key, hash: Array(SHA384.hash(data: data))))
        case "ecdsa-sha2-nistp521":
            return (identity.algorithm,
                    try signECDSA(key: key, hash: Array(SHA512.hash(data: data))))

        default:
            throw SignError.unsupportedAlgorithm(identity.algorithm)
        }
    }

    private func signEd25519(key: NamedKey, message: [UInt8]) throws -> [UInt8] {
        let ctx = try loadKey(key) { ctx, pem, pass in
            _libssh2_ed25519_new_private_frommemory(ctx, self.session, pem,
                                                    key.privateKeyPEM.utf8.count, pass)
        }
        // Without this the private key leaks on every signature — the one
        // allocation in the app that holds key material.
        defer { EVP_PKEY_free(ctx) }

        var signature: UnsafeMutablePointer<UInt8>?
        var length = 0
        // Ed25519 takes the message, not a digest — it hashes internally.
        let rc = message.withUnsafeBufferPointer { messagePtr in
            _libssh2_ed25519_sign(ctx, session, &signature, &length,
                                  messagePtr.baseAddress, message.count)
        }
        return try collect(rc: rc, signature: signature, length: length)
    }

    private func signRSA(key: NamedKey, hash: [UInt8]) throws -> [UInt8] {
        let ctx = try loadKey(key) { ctx, pem, pass in
            _libssh2_rsa_new_private_frommemory(ctx, self.session, pem,
                                                key.privateKeyPEM.utf8.count, pass)
        }
        defer { EVP_PKEY_free(ctx) }

        var signature: UnsafeMutablePointer<UInt8>?
        var length = 0
        // libssh2 picks SHA-256 vs SHA-512 from hash_len, so the digest the
        // caller chose from the request flags is what decides the algorithm.
        let rc = hash.withUnsafeBufferPointer { hashPtr in
            _libssh2_rsa_sha2_sign(session, ctx, hashPtr.baseAddress, hash.count,
                                   &signature, &length)
        }
        return try collect(rc: rc, signature: signature, length: length)
    }

    private func signECDSA(key: NamedKey, hash: [UInt8]) throws -> [UInt8] {
        let ctx = try loadKey(key) { ctx, pem, pass in
            _libssh2_ecdsa_new_private_frommemory(ctx, self.session, pem,
                                                  key.privateKeyPEM.utf8.count, pass)
        }
        defer { EVP_PKEY_free(ctx) }

        var signature: UnsafeMutablePointer<UInt8>?
        var length = 0
        let rc = hash.withUnsafeBufferPointer { hashPtr in
            _libssh2_ecdsa_sign(session, ctx, hashPtr.baseAddress, hash.count,
                                &signature, &length)
        }
        // libssh2 emits mpint r ‖ mpint s here, which is already the inner
        // payload an ECDSA signature blob carries — no reformatting.
        return try collect(rc: rc, signature: signature, length: length)
    }

    /// Loads a private key through one of libssh2's `*_new_private_frommemory`
    /// functions. They share a shape — `(ctx**, session, pem, pem_len,
    /// passphrase)` — so the three signers differ only in which one they name.
    ///
    /// The passphrase parameter is `unsigned const char *` on these three but
    /// plain `const char *` on `_libssh2_pub_priv_keyfilememory`, which is why
    /// the rebinding happens here rather than in a shared helper.
    private func loadKey(
        _ key: NamedKey,
        _ load: (UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                 UnsafePointer<CChar>,
                 UnsafePointer<UInt8>?) -> Int32
    ) throws -> UnsafeMutableRawPointer {
        var ctx: UnsafeMutableRawPointer?
        let rc = key.privateKeyPEM.withCString { pemPtr -> Int32 in
            guard let passphrase = key.passphrase else { return load(&ctx, pemPtr, nil) }
            return passphrase.withCString { passPtr in
                load(&ctx, pemPtr,
                     UnsafeRawPointer(passPtr).assumingMemoryBound(to: UInt8.self))
            }
        }
        guard rc == 0, let ctx else { throw SignError.keyUnreadable(key.name) }
        return ctx
    }

    private func collect(rc: Int32,
                         signature: UnsafeMutablePointer<UInt8>?,
                         length: Int) throws -> [UInt8] {
        guard rc == 0, let signature else { throw SignError.signingFailed(rc) }
        defer { free(signature) }
        return Array(UnsafeBufferPointer(start: signature, count: length))
    }

    // MARK: Test-only verification

    #if DEBUG
    /// Verifies a signature through libssh2's own verify functions.
    ///
    /// Test-only, and deliberately so: nothing in the app verifies its own
    /// signatures. It exists because `libssh2-internal.h` declares prototypes
    /// libssh2 never promised to keep — if one drifts, this fails loudly in
    /// CI instead of producing signatures that remotes silently reject.
    ///
    /// Unlike the sign side, libssh2's verify functions take the *raw
    /// message* and hash it themselves (`hash_len`/the curve just selects
    /// which digest) — confirmed against libssh2 1.11.1's src/openssl.c,
    /// since the header alone doesn't say so and the two directions are not
    /// symmetric.
    func verifyForTesting(identity: AgentIdentity,
                          signature: [UInt8],
                          message: [UInt8],
                          flags: UInt32 = 0) -> Bool {
        guard let key = keysByName[identity.keyName] else { return false }

        switch identity.algorithm {
        case "ssh-ed25519":
            return verifyEd25519(key: key, signature: signature, message: message)
        case "ssh-rsa":
            let hashLength: Int
            if flags & AgentSignFlags.rsaSHA2_512 != 0 {
                hashLength = Int(SHA512.byteCount)
            } else if flags & AgentSignFlags.rsaSHA2_256 != 0 {
                hashLength = Int(SHA256.byteCount)
            } else {
                return false   // no SHA-2 flag: sign() would have refused this
            }
            return verifyRSA(key: key, hashLength: hashLength, signature: signature, message: message)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return verifyECDSA(key: key, signature: signature, message: message)
        default:
            return false
        }
    }

    private func verifyEd25519(key: NamedKey, signature: [UInt8], message: [UInt8]) -> Bool {
        guard let ctx = try? loadKey(key, { ctx, pem, pass in
            _libssh2_ed25519_new_private_frommemory(ctx, self.session, pem,
                                                    key.privateKeyPEM.utf8.count, pass)
        }) else { return false }
        defer { EVP_PKEY_free(ctx) }

        let rc = signature.withUnsafeBufferPointer { sigPtr in
            message.withUnsafeBufferPointer { messagePtr in
                _libssh2_ed25519_verify(ctx, sigPtr.baseAddress, signature.count,
                                        messagePtr.baseAddress, message.count)
            }
        }
        return rc == 0
    }

    private func verifyRSA(key: NamedKey, hashLength: Int,
                           signature: [UInt8], message: [UInt8]) -> Bool {
        guard let ctx = try? loadKey(key, { ctx, pem, pass in
            _libssh2_rsa_new_private_frommemory(ctx, self.session, pem,
                                                key.privateKeyPEM.utf8.count, pass)
        }) else { return false }
        defer { EVP_PKEY_free(ctx) }

        let rc = signature.withUnsafeBufferPointer { sigPtr in
            message.withUnsafeBufferPointer { messagePtr in
                _libssh2_rsa_sha2_verify(ctx, hashLength, sigPtr.baseAddress, signature.count,
                                        messagePtr.baseAddress, message.count)
            }
        }
        return rc == 0
    }

    private func verifyECDSA(key: NamedKey, signature: [UInt8], message: [UInt8]) -> Bool {
        guard let ctx = try? loadKey(key, { ctx, pem, pass in
            _libssh2_ecdsa_new_private_frommemory(ctx, self.session, pem,
                                                  key.privateKeyPEM.utf8.count, pass)
        }) else { return false }
        defer { EVP_PKEY_free(ctx) }

        // libssh2 emits the signature as two consecutive length-prefixed
        // fields (mpint r ‖ mpint s) — the same encoding SSHWireReader reads
        // for any wire "string" — but `_libssh2_ecdsa_verify` wants r and s
        // as separate raw buffers.
        var reader = SSHWireReader(signature)
        guard let r = try? reader.readString(), let s = try? reader.readString(),
              reader.isAtEnd else { return false }

        let rc = r.withUnsafeBufferPointer { rPtr in
            s.withUnsafeBufferPointer { sPtr in
                message.withUnsafeBufferPointer { messagePtr in
                    _libssh2_ecdsa_verify(ctx, rPtr.baseAddress, r.count,
                                         sPtr.baseAddress, s.count,
                                         messagePtr.baseAddress, message.count)
                }
            }
        }
        return rc == 0
    }
    #endif
}

/// Runs `body` with a C string for the passphrase, or NULL when there is none.
/// libssh2 treats NULL and "" differently for some key formats.
private func withOptionalPassphrase<T>(_ passphrase: String?,
                                       _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let passphrase else { return body(nil) }
    return passphrase.withCString { body($0) }
}
#endif
