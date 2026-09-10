// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// Shallow classification of bytes that claim to be a private key, shared by
/// every path that imports one: the `sloop` CLI, the host editor's paste field,
/// an SFTP pull from a host, and a file picked out of Files.app.
///
/// **This deliberately says nothing about whether a key is encrypted.** That
/// question is answerable only by attempting the parse, which needs libssh2 and
/// therefore happens a layer up in `KeyValidator`. Inferring it from the
/// envelope is what `KeyCLI.isEncryptedPEM` did — it searched for the literal
/// string `ENCRYPTED` and for `bcrypt` in the decoded body, and so missed an
/// OpenSSH-format key using any other KDF, silently storing it with no
/// passphrase and failing at connect time instead.
///
/// What this layer is for is refusing input that is plainly not a private key,
/// early and by name, so the user is told which mistake they made rather than
/// discovering hours later that a host will not authenticate. Foundation-only,
/// so it runs in Linux CI.
///
/// Design: `Docs/superpowers/specs/2026-08-19-key-import-design.md`.
public enum PrivateKeyMaterial {

    /// The PEM label found. A description of what was read, not a judgement
    /// about it — notably, `.pkcs8Encrypted` records the label that was there
    /// and is not the app's answer to "does this need a passphrase".
    public enum Envelope: Equatable {
        case openssh        // -----BEGIN OPENSSH PRIVATE KEY-----
        case pkcs8          // -----BEGIN PRIVATE KEY-----
        case pkcs8Encrypted // -----BEGIN ENCRYPTED PRIVATE KEY-----
        case rsa            // -----BEGIN RSA PRIVATE KEY-----
        case ec             // -----BEGIN EC PRIVATE KEY-----
        case dsa            // -----BEGIN DSA PRIVATE KEY-----
    }

    /// Why the bytes were refused. Each case exists because it maps to a
    /// different thing for the user to do about it.
    public enum Rejection: Error, Equatable {
        /// Nothing, or nothing but whitespace.
        case empty
        /// Not UTF-8 text, or contains a NUL. A binary file picked by mistake.
        case notText
        /// An OpenSSH `.pub` line. The likeliest wrong file in any picker.
        case publicKey
        /// A `known_hosts` entry: a host pattern followed by a public key.
        case knownHosts
        /// Text, but with no PEM envelope at all — an `ssh_config`, a README.
        case noPEMEnvelope
        /// A `BEGIN` line with no matching `END`. Almost always a copy-paste
        /// that dropped the tail, and worth distinguishing so the user is not
        /// sent hunting for a passphrase they never set.
        case truncated
    }

    public struct Recognized: Equatable {
        /// The PEM, trimmed of surrounding whitespace and otherwise
        /// byte-identical to the input. libssh2 parses the armor itself, so
        /// re-wrapping or normalizing it here would only be a chance to
        /// corrupt a key.
        public let pem: String
        public let envelope: Envelope
    }

    private static let envelopesByLabel: [String: Envelope] = [
        "OPENSSH PRIVATE KEY": .openssh,
        "PRIVATE KEY": .pkcs8,
        "ENCRYPTED PRIVATE KEY": .pkcs8Encrypted,
        "RSA PRIVATE KEY": .rsa,
        "EC PRIVATE KEY": .ec,
        "DSA PRIVATE KEY": .dsa,
    ]

    private static let publicKeyAlgorithms: Set<String> = [
        "ssh-rsa", "ssh-dss", "ssh-ed25519", "ssh-ed448",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    public static func recognize(_ data: Data) -> Result<Recognized, Rejection> {
        if data.isEmpty { return .failure(.empty) }
        // A NUL is valid UTF-8 but never appears in a PEM, and catching it
        // here is what turns "picked a binary file" into a sentence rather
        // than a parse error from three layers down.
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return .failure(.notText)
        }

        let pem = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pem.isEmpty { return .failure(.empty) }

        if let (label, envelope) = beginLabel(in: pem) {
            guard pem.contains("-----END \(label)-----") else { return .failure(.truncated) }
            return .success(Recognized(pem: pem, envelope: envelope))
        }
        // A BEGIN line for something that is not a private key — a
        // certificate, a CSR — is not a truncated key, it is the wrong file.
        if pem.contains("-----BEGIN ") { return .failure(.noPEMEnvelope) }

        return .failure(publicKeyShapedRejection(pem))
    }

    private static func beginLabel(in pem: String) -> (String, Envelope)? {
        for (label, envelope) in envelopesByLabel where pem.contains("-----BEGIN \(label)-----") {
            return (label, envelope)
        }
        return nil
    }

    /// Distinguishes a `.pub` from a `known_hosts` line by where the algorithm
    /// sits: a public key leads with it, a known-hosts entry has a host
    /// pattern in front.
    private static func publicKeyShapedRejection(_ pem: String) -> Rejection {
        guard let line = pem.split(separator: "\n").first(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }) else { return .noPEMEnvelope }

        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = fields.first else { return .noPEMEnvelope }
        if isPublicKeyAlgorithm(first) { return .publicKey }
        if fields.dropFirst().contains(where: isPublicKeyAlgorithm) { return .knownHosts }
        return .noPEMEnvelope
    }

    private static func isPublicKeyAlgorithm(_ field: String) -> Bool {
        if publicKeyAlgorithms.contains(field) { return true }
        // Certificate variants: ssh-ed25519-cert-v01@openssh.com and friends.
        guard let base = field.range(of: "-cert-v01@openssh.com", options: .backwards),
              base.upperBound == field.endIndex else { return false }
        return publicKeyAlgorithms.contains(String(field[field.startIndex..<base.lowerBound]))
    }

    // MARK: Names

    /// The library name to offer for a key read from `path`.
    ///
    /// Backslashes are separators too — this feature exists for people whose
    /// keys are on Windows.
    public static func defaultName(forPath path: String) -> String {
        let basename = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""

        var name = basename
        for suffix in [".pem", ".key"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.isEmpty ? "imported-key" : name
    }

    /// Whether a name in `~/.ssh` is worth offering as a private key.
    ///
    /// By name, never by content: classifying by content would mean pulling
    /// every private key in the directory off the server just to decide what
    /// to show, which is precisely what an import feature must not do
    /// speculatively.
    public static func mayBePrivateKeyFile(named name: String) -> Bool {
        if name.isEmpty || name.hasPrefix(".") { return false }
        if name.hasSuffix(".pub") { return false }
        if name.hasPrefix("known_hosts") || name.hasPrefix("authorized_keys") { return false }
        return !["config", "environment", "rc"].contains(name)
    }
}
