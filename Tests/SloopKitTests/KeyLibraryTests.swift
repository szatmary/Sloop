// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class KeyLibraryTests: XCTestCase {
    private func host(auth: AuthMethod) -> SSHHost {
        SSHHost(alias: "web", hostname: "example.com", username: "matt", auth: auth)
    }

    func testResolvesLibraryKeyByName() throws {
        let keys = InMemoryKeyStore()
        try keys.setKey(NamedKey(name: "id_ed25519", privateKeyPEM: "pem", passphrase: "pp"))
        let credential = KeyLibrary.credential(for: host(auth: .publicKey(name: "id_ed25519")),
                                               keys: keys,
                                               credentials: InMemoryCredentialStore())
        XCTAssertEqual(credential, Credential(privateKeyPEM: "pem", passphrase: "pp"))
    }

    func testFallsBackToLegacyPerHostCredential() throws {
        let credentials = InMemoryCredentialStore()
        let h = host(auth: .publicKey(name: "web"))
        try credentials.setCredential(Credential(privateKeyPEM: "legacy-pem"), for: h.id)
        let credential = KeyLibrary.credential(for: h,
                                               keys: InMemoryKeyStore(),
                                               credentials: credentials)
        XCTAssertEqual(credential, Credential(privateKeyPEM: "legacy-pem"))
    }

    func testLegacyPasswordOnlyCredentialNeverAnswersAPublicKeyHost() throws {
        // A host that was migrated to key auth (`.publicKey`), has no
        // matching library key (removed, or never migrated), but still has
        // a *password-only* legacy Credential on file — e.g. it was a
        // password host before the switch. Falling back to that credential
        // would hand LibSSH2Transport a password, and it silently re-sends
        // it as if the user never switched to key auth. Must resolve to nil,
        // not the stale password.
        let credentials = InMemoryCredentialStore()
        let h = host(auth: .publicKey(name: "web"))
        try credentials.setCredential(Credential(password: "stale-password"), for: h.id)
        let credential = KeyLibrary.credential(for: h,
                                               keys: InMemoryKeyStore(),
                                               credentials: credentials)
        XCTAssertNil(credential)
    }

    func testLibraryWinsOverLegacyCredential() throws {
        let keys = InMemoryKeyStore()
        try keys.setKey(NamedKey(name: "web", privateKeyPEM: "library-pem"))
        let credentials = InMemoryCredentialStore()
        let h = host(auth: .publicKey(name: "web"))
        try credentials.setCredential(Credential(privateKeyPEM: "legacy-pem"), for: h.id)
        XCTAssertEqual(KeyLibrary.credential(for: h, keys: keys, credentials: credentials)?.privateKeyPEM,
                       "library-pem")
    }

    func testPasswordHostsUsePerHostCredential() throws {
        let credentials = InMemoryCredentialStore()
        let h = host(auth: .password)
        try credentials.setCredential(Credential(password: "hunter2"), for: h.id)
        XCTAssertEqual(KeyLibrary.credential(for: h, keys: InMemoryKeyStore(), credentials: credentials),
                       Credential(password: "hunter2"))
    }

    func testMigrationLiftsPerHostPEMsIntoLibrary() throws {
        let credentials = InMemoryCredentialStore()
        let keys = InMemoryKeyStore()
        let h = host(auth: .publicKey(name: "web"))
        try credentials.setCredential(Credential(privateKeyPEM: "pem", passphrase: "pp"), for: h.id)

        KeyLibrary.migrate(hosts: [h], credentials: credentials, keys: keys)
        XCTAssertEqual(keys.key(named: "web"),
                       NamedKey(name: "web", privateKeyPEM: "pem", passphrase: "pp"))
    }

    func testMigrationNeverOverwritesExistingLibraryEntry() throws {
        let credentials = InMemoryCredentialStore()
        let keys = InMemoryKeyStore()
        try keys.setKey(NamedKey(name: "web", privateKeyPEM: "newer-pem"))
        let h = host(auth: .publicKey(name: "web"))
        try credentials.setCredential(Credential(privateKeyPEM: "old-pem"), for: h.id)

        KeyLibrary.migrate(hosts: [h], credentials: credentials, keys: keys)
        XCTAssertEqual(keys.key(named: "web")?.privateKeyPEM, "newer-pem")
    }

    func testMigrationSkipsPasswordHostsAndHostsWithoutPEM() throws {
        let credentials = InMemoryCredentialStore()
        let keys = InMemoryKeyStore()
        let pw = host(auth: .password)
        try credentials.setCredential(Credential(password: "hunter2"), for: pw.id)
        let keyless = host(auth: .publicKey(name: "bare"))

        KeyLibrary.migrate(hosts: [pw, keyless], credentials: credentials, keys: keys)
        XCTAssertTrue(keys.keys().isEmpty)
    }

    /// The public key must reach the transport: libssh2's mbedTLS backend
    /// can't derive it from the private key, so dropping it here breaks every
    /// key authentication — the bug that made SSH unusable on device.
    func testResolvedCredentialCarriesThePublicKey() throws {
        let keys = InMemoryKeyStore()
        try keys.setKey(NamedKey(name: "id_rsa",
                                 privateKeyPEM: "pem",
                                 publicKey: "ssh-rsa AAAAB3Nz…",
                                 passphrase: nil))
        let credential = KeyLibrary.credential(for: host(auth: .publicKey(name: "id_rsa")),
                                               keys: keys,
                                               credentials: InMemoryCredentialStore())
        XCTAssertEqual(credential?.publicKey, "ssh-rsa AAAAB3Nz…")
        XCTAssertEqual(credential?.privateKeyPEM, "pem")
    }
}
