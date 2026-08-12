# Shared SSH Key Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A named key library — import an SSH private key once (CLI on the Mac), reference it from any host, synced to all the user's devices via iCloud Keychain.

**Architecture:** SloopKit gains `NamedKey`, a `KeyStore` protocol, pure connect-time resolution and migration functions (all unit-tested against in-memory stores). The app gains `KeychainKeyStore` (synchronizable keychain items in the shared access group `KR5WZAG3UE.org.szatmary.sloop.shared`), a CLI subcommand embedded in the macOS app binary, and a key picker in the host editor. Spec: `Docs/superpowers/specs/2026-08-11-key-library-design.md`.

**Tech Stack:** Swift 5.9, SwiftUI, Security.framework keychain (no new dependencies).

## Global Constraints

- Deployment targets: iOS 17.0, macOS 14.0. `ARCHS: arm64` only.
- Team ID `KR5WZAG3UE`; bundle id `org.szatmary.sloop`; shared keychain access group is exactly `KR5WZAG3UE.org.szatmary.sloop.shared`.
- SloopKit stays Foundation-only (no Security import in `Sources/SloopKit`); keychain code lives in `App/Sloop`.
- After editing any `project*.yml`, regenerate with `xcodegen generate --spec project.mosh.yml` before building.
- SloopKit tests run with `swift test`. App tests: `xcodebuild test -scheme Sloop_macOS -project Sloop.xcodeproj -destination 'platform=macOS'` (needs the generated project and `Vendor/` xcframeworks; both exist in the working tree).
- Commit messages: imperative summary line, explanatory body, ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- The unsigned CI macOS build cannot exercise the shared synced keychain (entitlements need real signing). Never "fix" that with a silent fallback — `KeychainKeyStore` must throw descriptive errors.

---

### Task 1: SloopKit — `NamedKey`, `KeyStore`, `InMemoryKeyStore`

**Files:**
- Create: `Sources/SloopKit/Model/KeyStore.swift`
- Test: `Tests/SloopKitTests/KeyStoreTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `NamedKey(name: String, privateKeyPEM: String, passphrase: String?)` (Codable, Equatable, Identifiable via `name`); `protocol KeyStore: AnyObject { func keys() -> [NamedKey]; func key(named: String) -> NamedKey?; func setKey(_ key: NamedKey) throws; func removeKey(named: String) throws }`; `final class InMemoryKeyStore: KeyStore`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SloopKitTests/KeyStoreTests.swift
import XCTest
@testable import SloopKit

final class KeyStoreTests: XCTestCase {
    private let ed25519 = NamedKey(name: "id_ed25519",
                                   privateKeyPEM: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----",
                                   passphrase: nil)

    func testSetGetRemoveRoundTrip() throws {
        let store = InMemoryKeyStore()
        XCTAssertNil(store.key(named: "id_ed25519"))
        try store.setKey(ed25519)
        XCTAssertEqual(store.key(named: "id_ed25519"), ed25519)
        try store.removeKey(named: "id_ed25519")
        XCTAssertNil(store.key(named: "id_ed25519"))
    }

    func testSetKeyWithSameNameReplaces() throws {
        let store = InMemoryKeyStore()
        try store.setKey(ed25519)
        var updated = ed25519
        updated.passphrase = "secret"
        try store.setKey(updated)
        XCTAssertEqual(store.keys().count, 1)
        XCTAssertEqual(store.key(named: "id_ed25519")?.passphrase, "secret")
    }

    func testKeysAreSortedByName() throws {
        let store = InMemoryKeyStore()
        try store.setKey(NamedKey(name: "work", privateKeyPEM: "pem-b", passphrase: nil))
        try store.setKey(ed25519)
        XCTAssertEqual(store.keys().map(\.name), ["id_ed25519", "work"])
    }

    func testRemoveMissingKeyDoesNotThrow() {
        XCTAssertNoThrow(try InMemoryKeyStore().removeKey(named: "absent"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeyStoreTests 2>&1 | tail -5`
Expected: compile FAILURE — `NamedKey` and `InMemoryKeyStore` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/SloopKit/Model/KeyStore.swift
import Foundation

/// A private key in the shared key library, referenced from hosts by
/// `AuthMethod.publicKey(name:)`. The library is the "import once, use from
/// any host" tier; per-host `Credential`s remain the legacy/fallback tier.
public struct NamedKey: Codable, Equatable, Identifiable {
    /// Unique within the library, e.g. "id_ed25519".
    public var name: String
    public var privateKeyPEM: String
    public var passphrase: String?

    public var id: String { name }

    public init(name: String, privateKeyPEM: String, passphrase: String? = nil) {
        self.name = name
        self.privateKeyPEM = privateKeyPEM
        self.passphrase = passphrase
    }
}

/// Where library keys live. The app ships a keychain-backed implementation
/// (synchronizable via iCloud Keychain); tests use `InMemoryKeyStore`. A
/// protocol in SloopKit so resolution/migration logic stays Foundation-only.
public protocol KeyStore: AnyObject {
    /// All keys, sorted by name.
    func keys() -> [NamedKey]
    func key(named name: String) -> NamedKey?
    /// Insert or replace the key with the same name.
    func setKey(_ key: NamedKey) throws
    /// Removing an absent name is not an error.
    func removeKey(named name: String) throws
}

/// A non-persistent key store for tests and previews.
public final class InMemoryKeyStore: KeyStore {
    private var storage: [String: NamedKey] = [:]

    public init() {}

    public func keys() -> [NamedKey] {
        storage.values.sorted { $0.name < $1.name }
    }
    public func key(named name: String) -> NamedKey? { storage[name] }
    public func setKey(_ key: NamedKey) throws { storage[key.name] = key }
    public func removeKey(named name: String) throws { storage[name] = nil }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeyStoreTests 2>&1 | tail -3`
Expected: `Test Suite 'KeyStoreTests' passed`, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SloopKit/Model/KeyStore.swift Tests/SloopKitTests/KeyStoreTests.swift
git commit -m "SloopKit: NamedKey + KeyStore protocol + InMemoryKeyStore

First slice of the shared key library (spec:
Docs/superpowers/specs/2026-08-11-key-library-design.md). Protocol lives in
SloopKit so resolution and migration stay Foundation-only and unit-testable;
the keychain-backed implementation comes in the app layer.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: SloopKit — connect-time resolution + migration

**Files:**
- Create: `Sources/SloopKit/Model/KeyLibrary.swift`
- Test: `Tests/SloopKitTests/KeyLibraryTests.swift`

**Interfaces:**
- Consumes: `NamedKey`, `KeyStore` (Task 1); existing `SSHHost`, `AuthMethod`, `Credential`, `CredentialStore`.
- Produces: `enum KeyLibrary` with:
  - `static func credential(for host: SSHHost, keys: KeyStore, credentials: CredentialStore) -> Credential?`
  - `static func migrate(hosts: [SSHHost], credentials: CredentialStore, keys: KeyStore)`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/SloopKitTests/KeyLibraryTests.swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeyLibraryTests 2>&1 | tail -5`
Expected: compile FAILURE — `KeyLibrary` not defined.

- [ ] **Step 3: Implement**

```swift
// Sources/SloopKit/Model/KeyLibrary.swift
import Foundation

/// Connect-time key resolution and one-time migration for the shared key
/// library. Pure functions over the store protocols so both are unit-testable
/// without the keychain.
public enum KeyLibrary {
    /// The credential to hand the SSH transport for `host`.
    ///
    /// `.publicKey(name:)` prefers the library key of that name; if the
    /// library has none (pre-migration data, or a removed key) it falls back
    /// to the legacy per-host credential. Password hosts always use the
    /// per-host credential.
    public static func credential(for host: SSHHost,
                                  keys: KeyStore,
                                  credentials: CredentialStore) -> Credential? {
        if case .publicKey(let name) = host.auth, let key = keys.key(named: name) {
            return Credential(privateKeyPEM: key.privateKeyPEM, passphrase: key.passphrase)
        }
        return credentials.credential(for: host.id)
    }

    /// Lift legacy per-host PEMs into the library, named by each host's
    /// existing `.publicKey(name:)`. Idempotent: existing library entries are
    /// never overwritten (they may be newer, or synced from another device).
    /// The per-host copy is left in place as the fallback tier.
    public static func migrate(hosts: [SSHHost],
                               credentials: CredentialStore,
                               keys: KeyStore) {
        for host in hosts {
            guard case .publicKey(let name) = host.auth,
                  keys.key(named: name) == nil,
                  let credential = credentials.credential(for: host.id),
                  let pem = credential.privateKeyPEM else { continue }
            try? keys.setKey(NamedKey(name: name,
                                      privateKeyPEM: pem,
                                      passphrase: credential.passphrase))
        }
    }
}
```

Note the `try?` in `migrate`: a migration pass must not abort on one bad key,
and the caller re-runs it every launch — but do NOT copy that pattern into
`KeychainKeyStore` itself, which must throw.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: all SloopKit suites pass (run the full suite to catch regressions).

- [ ] **Step 5: Commit**

```bash
git add Sources/SloopKit/Model/KeyLibrary.swift Tests/SloopKitTests/KeyLibraryTests.swift
git commit -m "SloopKit: KeyLibrary — connect-time resolution + migration

.publicKey(name:) resolves against the key library first, then the legacy
per-host credential (the pre-migration tier, not error masking). migrate()
lifts per-host PEMs into the library idempotently, never overwriting
existing entries.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: App — `KeychainKeyStore` + shared-keychain entitlements

**Files:**
- Create: `App/Sloop/SSH/KeychainKeyStore.swift`
- Create: `App/Sloop/Sloop.entitlements`
- Modify: `project.yml` (the `SloopApp` template's `settings.base`)

**Interfaces:**
- Consumes: `NamedKey`, `KeyStore` (Task 1).
- Produces: `final class KeychainKeyStore: KeyStore` with `init(service: String = "org.szatmary.sloop.keys", accessGroup: String? = KeychainKeyStore.sharedAccessGroup)` and `static let sharedAccessGroup = "KR5WZAG3UE.org.szatmary.sloop.shared"`. Tasks 4 and 5 construct it as `KeychainKeyStore()`.

No unit test: the synced keychain needs a signed, entitled process, which CI
and `swift test` don't have. Verification is the build gate here; runtime
verification happens in Tasks 4–5 (CLI import on the Mac, picker on the iPad).

- [ ] **Step 1: Implement the store**

```swift
// App/Sloop/SSH/KeychainKeyStore.swift
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
    static let sharedAccessGroup = "KR5WZAG3UE.org.szatmary.sloop.shared"

    private let service: String
    private let accessGroup: String?

    init(service: String = "org.szatmary.sloop.keys",
         accessGroup: String? = KeychainKeyStore.sharedAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func keys() -> [NamedKey] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Data] else { return [] }
        return items
            .compactMap { try? JSONDecoder().decode(NamedKey.self, from: $0) }
            .sorted { $0.name < $1.name }
    }

    func key(named name: String) -> NamedKey? {
        var query = baseQuery(account: name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(NamedKey.self, from: data)
    }

    func setKey(_ key: NamedKey) throws {
        let data = try JSONEncoder().encode(key)
        let query = baseQuery(account: key.name)

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw keychainError(update, "updating key '\(key.name)'") }
        } else {
            var insert = query
            insert[kSecValueData as String] = data
            // AfterFirstUnlock, NOT ...ThisDeviceOnly: device-only items are
            // excluded from iCloud Keychain sync.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey:
                                    "Keychain error \(doing): \(message). " +
                                    "Shared-keychain access requires a signed build (see SIGNING.md)."])
    }
}
#endif
```

Nuance: new items must be *created* synchronizable. `kSecAttrSynchronizableAny`
is only valid in *search* queries, so `setKey`'s insert path must override it:
after `var insert = query`, add
`insert[kSecAttrSynchronizable as String] = true`
(place it right beside the `kSecAttrAccessible` line).

- [ ] **Step 2: Create the entitlements file**

```xml
<!-- App/Sloop/Sloop.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)org.szatmary.sloop.shared</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 3: Wire entitlements into the shared target template**

In `project.yml`, inside `targetTemplates: SloopApp: settings: base:`, next to
`ASSETCATALOG_COMPILER_APPICON_NAME`, add:

```yaml
        # Shared keychain group for the key library (iCloud-synced). Only
        # effective in signed builds; see SIGNING.md.
        CODE_SIGN_ENTITLEMENTS: App/Sloop/Sloop.entitlements
```

The entitlements file must ALSO be excluded from bundle resources (it sits in
the sources directory). In the template's `sources:` entry, extend `excludes`:

```yaml
    sources:
      - path: App/Sloop
        excludes:
          # Master art for Scripts/generate-appicon.sh — not a bundle resource.
          - AppIcon.svg
          # Build input for CODE_SIGN_ENTITLEMENTS — not a bundle resource.
          - Sloop.entitlements
```

- [ ] **Step 4: Regenerate and build both platforms**

Run:
```bash
xcodegen generate --spec project.mosh.yml
xcodebuild -project Sloop.xcodeproj -scheme Sloop_macOS -configuration Debug build -quiet 2>&1 | tail -3
xcodebuild -project Sloop.xcodeproj -scheme Sloop_iOS -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates DEVELOPMENT_TEAM=KR5WZAG3UE CODE_SIGN_STYLE=Automatic build 2>&1 | grep -E "error|BUILD" | sort -u
```
Expected: both `BUILD SUCCEEDED`. If iOS signing complains about the keychain
entitlement, re-run with `-allowProvisioningUpdates` present (Xcode must mint
a profile that includes keychain-access-groups; this is automatic).

- [ ] **Step 5: Commit**

```bash
git add App/Sloop/SSH/KeychainKeyStore.swift App/Sloop/Sloop.entitlements project.yml
git commit -m "App: KeychainKeyStore — synced, shared-access-group key storage

Generic-password items (account = key name, JSON NamedKey payload), marked
synchronizable so iCloud Keychain carries the library to all devices, in the
KR5WZAG3UE.org.szatmary.sloop.shared access group declared by the new
Sloop.entitlements (both app targets via the shared template). Data
protection keychain on macOS. Errors carry the OSStatus message and point at
SIGNING.md — unsigned builds cannot reach the shared keychain.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: macOS CLI — `sloop import-key` embedded in the app binary

**Files:**
- Create: `App/Sloop/KeyCLI.swift`
- Create: `Scripts/sloop` (mode 755)
- Modify: `App/Sloop/SloopApp.swift` (move `@main` to a launcher enum)
- Test: `Tests/SloopAppTests/KeyCLITests.swift` (add a new file beside `SloopAppTests.swift`)

**Interfaces:**
- Consumes: `NamedKey`, `KeychainKeyStore` (Tasks 1, 3).
- Produces: `enum KeyCLI` with `static func parse(_ arguments: [String]) -> Command?`, `enum Command: Equatable { case importKey(path: String, name: String?); case listKeys; case removeKey(name: String) }`, and `static func run(arguments: [String]) -> Bool` (true = handled, caller must not start the GUI).

- [ ] **Step 1: Write the failing parser tests**

```swift
// Tests/SloopAppTests/KeyCLITests.swift
import XCTest
@testable import Sloop_macOS

final class KeyCLITests: XCTestCase {
    func testParsesImportKeyWithDefaultName() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "/Users/m/.ssh/id_ed25519"]),
                       .importKey(path: "/Users/m/.ssh/id_ed25519", name: nil))
    }

    func testParsesImportKeyWithExplicitName() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--name", "work"]),
                       .importKey(path: "k.pem", name: "work"))
    }

    func testParsesListAndRemove() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "list-keys"]), .listKeys)
        XCTAssertEqual(KeyCLI.parse(["Sloop", "remove-key", "work"]), .removeKey(name: "work"))
    }

    func testNoSubcommandMeansGUILaunch() {
        XCTAssertNil(KeyCLI.parse(["Sloop"]))
        // Real app launches carry Apple flags like -NSDocumentRevisionsDebugMode;
        // anything that isn't a known subcommand must fall through to the GUI.
        XCTAssertNil(KeyCLI.parse(["Sloop", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testMalformedSubcommandsAreRejectedNotIgnored() {
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key"]), .usage)
        XCTAssertEqual(KeyCLI.parse(["Sloop", "remove-key"]), .usage)
        XCTAssertEqual(KeyCLI.parse(["Sloop", "import-key", "k.pem", "--name"]), .usage)
    }

    func testEncryptedPEMDetection() {
        XCTAssertTrue(KeyCLI.isEncryptedPEM("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC\n-----END RSA PRIVATE KEY-----"))
        XCTAssertFalse(KeyCLI.isEncryptedPEM("-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----"))
        // openssh-key-v1 with bcrypt KDF (encrypted): the decoded payload
        // contains "bcrypt". "b3BlbnNzaC1rZXktdjEAAAAABmJjcnlwdA==" decodes to
        // "openssh-key-v1\0...bcrypt".
        XCTAssertTrue(KeyCLI.isEncryptedPEM("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABmJjcnlwdA==\n-----END OPENSSH PRIVATE KEY-----"))
        // openssh-key-v1 with "none" cipher (unencrypted):
        // "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU=" decodes to "openssh-key-v1\0...none".
        XCTAssertFalse(KeyCLI.isEncryptedPEM("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----"))
    }
}
```

Note: the tests reference a `.usage` case — add it to `Command` (it prints
usage and exits 64). This keeps "malformed" distinct from "not a CLI launch".

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Sloop_macOS -project Sloop.xcodeproj -destination 'platform=macOS' -only-testing SloopTests/KeyCLITests 2>&1 | tail -5`
Expected: compile FAILURE — `KeyCLI` not defined.

- [ ] **Step 3: Implement `KeyCLI` and re-route `@main`**

```swift
// App/Sloop/KeyCLI.swift
import Foundation
import SloopKit

#if os(macOS)
/// Key-library subcommands embedded in the app binary, so imports run with
/// the app's signature and entitlements (a plain script cannot write the
/// shared, synchronizable keychain). Invoked via Scripts/sloop:
///
///     sloop import-key ~/.ssh/id_ed25519 [--name work]
///     sloop list-keys
///     sloop remove-key work
enum KeyCLI {
    enum Command: Equatable {
        case importKey(path: String, name: String?)
        case listKeys
        case removeKey(name: String)
        case usage
    }

    /// nil = not a CLI invocation; launch the GUI.
    static func parse(_ arguments: [String]) -> Command? {
        guard arguments.count >= 2 else { return nil }
        switch arguments[1] {
        case "import-key":
            guard arguments.count >= 3 else { return .usage }
            let path = arguments[2]
            if arguments.count == 3 { return .importKey(path: path, name: nil) }
            guard arguments.count == 5, arguments[3] == "--name" else { return .usage }
            return .importKey(path: path, name: arguments[4])
        case "list-keys":
            return .listKeys
        case "remove-key":
            guard arguments.count == 3 else { return .usage }
            return .removeKey(name: arguments[2])
        default:
            return nil  // GUI launch (possibly with Apple's -NS… flags)
        }
    }

    /// True when the process was a CLI invocation and has been handled;
    /// the caller must then skip starting SwiftUI.
    static func run(arguments: [String]) -> Bool {
        guard let command = parse(arguments) else { return false }
        let store = KeychainKeyStore()
        do {
            switch command {
            case .usage:
                FileHandle.standardError.write(Data(usageText.utf8))
                exit(64)  // EX_USAGE
            case .importKey(let path, let name):
                let pem = try String(contentsOfFile: (path as NSString).expandingTildeInPath,
                                     encoding: .utf8)
                var passphrase: String?
                if isEncryptedPEM(pem), let raw = getpass("Key passphrase: ") {
                    passphrase = String(cString: raw)
                }
                let keyName = name ?? ((path as NSString).lastPathComponent)
                try store.setKey(NamedKey(name: keyName, privateKeyPEM: pem, passphrase: passphrase))
                print("Imported '\(keyName)'. It will appear in Sloop on all your devices (iCloud Keychain).")
            case .listKeys:
                let keys = store.keys()
                if keys.isEmpty { print("No keys in the library.") }
                for key in keys {
                    print("\(key.name)\(key.passphrase != nil ? " (passphrase stored)" : "")")
                }
            case .removeKey(let name):
                try store.removeKey(named: name)
                print("Removed '\(name)'.")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        return true
    }

    /// Encrypted-PEM detection: PKCS#1/#8 headers say ENCRYPTED outright;
    /// openssh-key-v1 names its KDF ("bcrypt") in the base64 payload, which
    /// literally contains "none" instead when unencrypted.
    static func isEncryptedPEM(_ pem: String) -> Bool {
        if pem.contains("ENCRYPTED") { return true }
        let body = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let decoded = Data(base64Encoded: body),
              let text = String(data: decoded, encoding: .isoLatin1) else { return false }
        return text.contains("bcrypt")
    }

    private static let usageText = """
    usage: sloop import-key <path> [--name <name>]
           sloop list-keys
           sloop remove-key <name>

    """
}
#endif
```

Then re-route `@main` in `App/Sloop/SloopApp.swift`. Replace:

```swift
@main
struct SloopApp: App {
```

with:

```swift
/// CLI subcommands run before SwiftUI ever starts; a normal launch falls
/// through to the GUI. See KeyCLI.
@main
enum SloopMain {
    static func main() {
        #if os(macOS)
        if KeyCLI.run(arguments: CommandLine.arguments) { return }
        #endif
        SloopApp.main()
    }
}

struct SloopApp: App {
```

- [ ] **Step 4: Create the wrapper script**

```bash
#!/usr/bin/env bash
# Scripts/sloop — key-library CLI for Sloop.
#
#   sloop import-key ~/.ssh/id_ed25519 [--name work]
#   sloop list-keys
#   sloop remove-key <name>
#
# Thin exec wrapper: the real logic is inside the app binary (KeyCLI.swift),
# because writing the shared, iCloud-synced keychain requires the app's code
# signature and entitlements — a bare script cannot do it.
set -euo pipefail

for app in "/Applications/Sloop.app" "$HOME/Applications/Sloop.app"; do
  bin="$app/Contents/MacOS/Sloop_macOS"
  if [ -x "$bin" ]; then
    exec "$bin" "$@"
  fi
done
echo "error: Sloop.app not found in /Applications or ~/Applications" >&2
exit 1
```

Run: `chmod +x Scripts/sloop`

- [ ] **Step 5: Run the tests and the full macOS suite**

Run: `xcodebuild test -scheme Sloop_macOS -project Sloop.xcodeproj -destination 'platform=macOS' 2>&1 | tail -5`
Expected: all suites pass, including `KeyCLITests` (6 tests).

- [ ] **Step 6: Verify the CLI end-to-end on this Mac**

```bash
DD=$(mktemp -d)
xcodebuild -project Sloop.xcodeproj -scheme Sloop_macOS -configuration Debug \
  -derivedDataPath "$DD" DEVELOPMENT_TEAM=KR5WZAG3UE CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build -quiet
BIN="$DD/Build/Products/Debug/Sloop_macOS.app/Contents/MacOS/Sloop_macOS"
ssh-keygen -t ed25519 -N "" -f /tmp/sloop-test-key -q
"$BIN" import-key /tmp/sloop-test-key --name plan-test
"$BIN" list-keys        # expect: plan-test
"$BIN" remove-key plan-test
"$BIN" list-keys        # expect: No keys in the library.
rm /tmp/sloop-test-key /tmp/sloop-test-key.pub
```
Expected: exactly the outputs in the comments; any keychain error here means
the entitlements/signing wiring from Task 3 is wrong — stop and fix that
(root cause), do not work around it in the CLI.

- [ ] **Step 7: Commit**

```bash
git add App/Sloop/KeyCLI.swift App/Sloop/SloopApp.swift Scripts/sloop Tests/SloopAppTests/KeyCLITests.swift
git commit -m "macOS: sloop key CLI embedded in the app binary

import-key/list-keys/remove-key run before SwiftUI starts, using the app's
signature and entitlements to write the shared synced keychain — the reason
this is not a standalone script. Encrypted PEMs (PKCS ENCRYPTED header or
openssh-key-v1 bcrypt KDF) prompt for a passphrase, stored with the key.
Scripts/sloop is the exec wrapper.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: UI — key picker in the host editor + wiring + docs

**Files:**
- Modify: `App/Sloop/Views/HostListModel.swift` (init, `connect`)
- Modify: `App/Sloop/Views/HostEditView.swift` (auth section)
- Modify: `Docs/ROADMAP.md`, `Docs/HANDOFF.md` (feature notes)

**Interfaces:**
- Consumes: `KeyLibrary`, `KeychainKeyStore`, `InMemoryKeyStore`, `NamedKey` (Tasks 1–3).
- Produces: user-visible feature; no new API.

- [ ] **Step 1: Wire the key store into `HostListModel`**

In `App/Sloop/Views/HostListModel.swift`:

Add a `keys` store beside `credentials`, run migration once at init, and use
`KeyLibrary` at connect time. The full set of edits:

```swift
    private let store = HostStore()
    private let knownHosts = KnownHostsStore()
    private let credentials: CredentialStore
    private let keys: KeyStore          // ← add

    init() {
        #if canImport(Security)
        credentials = KeychainCredentialStore()
        keys = KeychainKeyStore()       // ← add
        #else
        credentials = InMemoryCredentialStore()
        keys = InMemoryKeyStore()       // ← add
        #endif
        hosts = store.hosts
        // Lift legacy per-host PEMs into the library (idempotent; never
        // overwrites entries that already exist or synced in).
        KeyLibrary.migrate(hosts: hosts, credentials: credentials, keys: keys)   // ← add
    }
```

In `connect(_:)`, replace:

```swift
        let credential = credentials.credential(for: host.id) ?? Credential()
```

with:

```swift
        let credential = KeyLibrary.credential(for: host, keys: keys, credentials: credentials)
            ?? Credential()
```

Expose the library to the editor sheet — add below `newHost()`:

```swift
    /// Library keys for the host editor's picker.
    func libraryKeys() -> [NamedKey] { keys.keys() }

    /// Store a pasted key into the shared library.
    func saveLibraryKey(_ key: NamedKey) throws { try keys.setKey(key) }
```

- [ ] **Step 2: Replace the Private Key pane in `HostEditView`**

`HostEditView` currently collects a PEM per host. It becomes: pick a library
key by name, or paste a new one (which saves INTO the library). The view needs
the library passed in, so its init grows two parameters with no behavior
change for password auth.

Replace the state block's key-related properties:

```swift
    @State private var authKind: AuthKind = .password
    @State private var password: String = ""
    @State private var privateKeyPEM: String = ""
    @State private var passphrase: String = ""
```

with:

```swift
    @State private var authKind: AuthKind = .password
    @State private var password: String = ""
    @State private var selectedKeyName: String = ""
    @State private var pastedPEM: String = ""
    @State private var pastedName: String = ""
    @State private var pastedPassphrase: String = ""
    private let libraryKeys: [NamedKey]
    private let onSaveKey: (NamedKey) throws -> Void
```

Replace the init:

```swift
    init(host: SSHHost,
         libraryKeys: [NamedKey] = [],
         onSaveKey: @escaping (NamedKey) throws -> Void = { _ in },
         onSave: @escaping (SSHHost, Credential?) -> Void) {
        _host = State(initialValue: host)
        self.libraryKeys = libraryKeys
        self.onSaveKey = onSaveKey
        self.onSave = onSave
        if case .publicKey(let name) = host.auth {
            _authKind = State(initialValue: .privateKey)
            _selectedKeyName = State(initialValue: name)
        }
    }
```

Replace the `case .privateKey:` section body (the `VStack` with the
`TextEditor` and the passphrase `SecureField`) with:

```swift
                    case .privateKey:
                        Picker("Key", selection: $selectedKeyName) {
                            Text("Paste new key…").tag("")
                            ForEach(libraryKeys) { key in
                                Text(key.name).tag(key.name)
                            }
                        }
                        if selectedKeyName.isEmpty {
                            TextField("Key name (e.g. id_ed25519)", text: $pastedName)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Private key (PEM)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $pastedPEM)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(minHeight: 120)
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    #endif
                            }
                            SecureField("Key passphrase (optional)", text: $pastedPassphrase)
                            Text("Saved to the key library (iCloud Keychain), shared by all your hosts and devices. On a Mac, `sloop import-key` is quicker.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
```

Also update the footer text that mentions per-host storage: change

```swift
                    Text("Stored in the keychain, never in the host list. Leave blank to keep the existing secret.")
```

to

```swift
                    Text("Secrets live in the keychain, never in the host list. Leave the password blank to keep the existing one.")
```

Replace the Save button's action and disabled modifier:

```swift
                    Button("Save") {
                        switch authKind {
                        case .password:
                            host.auth = .password
                            onSave(host, password.isEmpty ? nil : Credential(password: password))
                            dismiss()
                        case .privateKey:
                            do {
                                var name = selectedKeyName
                                if name.isEmpty {
                                    name = pastedName
                                    try onSaveKey(NamedKey(
                                        name: name,
                                        privateKeyPEM: pastedPEM,
                                        passphrase: pastedPassphrase.isEmpty ? nil : pastedPassphrase))
                                }
                                host.auth = .publicKey(name: name)
                                onSave(host, nil)
                                dismiss()
                            } catch {
                                saveError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(host.hostname.isEmpty || host.username.isEmpty
                              || (authKind == .privateKey && selectedKeyName.isEmpty
                                  && (pastedName.isEmpty || pastedPEM.isEmpty)))
```

Add the error state and alert (key saves can fail — unsigned build, keychain
denial — and must be shown, not swallowed). Add to the state block:

```swift
    @State private var saveError: String?
```

and attach to the `Form`, after `.navigationTitle(...)`:

```swift
            .alert("Couldn't Save Key", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } })
            ) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
```

Delete the now-unused `buildCredential()` helper entirely — password credential
construction moved inline, and key material no longer flows through
`Credential` at save time.

- [ ] **Step 3: Pass the library through from `HostListView`**

In `App/Sloop/Views/HostListView.swift`, replace the editor sheet:

```swift
            .sheet(item: $editing) { host in
                HostEditView(host: host) { model.save($0, credential: $1) }
            }
```

with:

```swift
            .sheet(item: $editing) { host in
                HostEditView(host: host,
                             libraryKeys: model.libraryKeys(),
                             onSaveKey: { try model.saveLibraryKey($0) }) {
                    model.save($0, credential: $1)
                }
            }
```

- [ ] **Step 4: Build both platforms and run all tests**

```bash
xcodegen generate --spec project.mosh.yml
swift test 2>&1 | tail -3
xcodebuild test -scheme Sloop_macOS -project Sloop.xcodeproj -destination 'platform=macOS' 2>&1 | tail -3
xcodebuild -project Sloop.xcodeproj -scheme Sloop_iOS -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates DEVELOPMENT_TEAM=KR5WZAG3UE CODE_SIGN_STYLE=Automatic build 2>&1 | grep -E "error|BUILD" | sort -u
```
Expected: SloopKit suites pass, macOS app suites pass, iOS `BUILD SUCCEEDED`.

- [ ] **Step 5: Manual verification (Mac + iPad)**

1. On the Mac: `Scripts/sloop import-key` a real key (or the Task 4 Step 6
   flow), open the signed local Sloop_macOS build, edit a host → Private Key →
   the imported name appears in the picker.
2. On the iPad (signed dev build, same Apple ID): edit the same host → the key
   name appears in the picker (iCloud Keychain may take a minute; both devices
   need iCloud Keychain enabled in Settings).
3. Connect to a host that accepts that key: login succeeds.
4. Airplane-test the fallback: a pre-existing host that used a pasted per-host
   key still connects (legacy tier).

- [ ] **Step 6: Update docs**

In `Docs/ROADMAP.md` under "Nice-to-have", replace the
`ssh-agent` / Secure Enclave line's context by adding directly above it:

```markdown
- ~~Key management~~ → DONE: shared key library synced via iCloud Keychain;
  `sloop import-key` CLI on the Mac (embedded in the app binary). Spec:
  `Docs/superpowers/specs/2026-08-11-key-library-design.md`.
```

In `Docs/HANDOFF.md`, in the "Done and green in CI" list, extend the host
management bullet:

```markdown
- **Host management**: keychain-backed credentials, host editor, **SSH config
  import/export** (`~/.ssh/config`), **shared key library** synced via iCloud
  Keychain with a Mac-side `sloop import-key` CLI (`Scripts/sloop`).
```

- [ ] **Step 7: Commit**

```bash
git add App/Sloop/Views/HostListModel.swift App/Sloop/Views/HostEditView.swift App/Sloop/Views/HostListView.swift Docs/ROADMAP.md Docs/HANDOFF.md
git commit -m "Host editor: pick keys from the shared library

The Private Key pane is now a picker over library key names; pasting a new
key stores it in the library (named, synced) instead of the per-host slot.
Connect resolves through KeyLibrary (library first, legacy per-host
fallback), and legacy PEMs migrate into the library at launch. Key-save
failures surface in an alert — unsigned builds can't reach the shared
keychain and must say so.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review Notes

- Spec coverage: §1 → Tasks 1–2, §2 → Task 3, §3 → Task 4, §4 → Task 5
  Steps 2–3, §5 migration → Task 2 (logic) + Task 5 Step 1 (call site),
  §6 testing → Tasks 1, 2, 4 test steps. Out-of-scope items untouched.
- Type consistency: `KeyStore.keys()/key(named:)/setKey/removeKey` used
  identically in Tasks 3–5; `KeyLibrary.credential(for:keys:credentials:)`
  and `migrate(hosts:credentials:keys:)` match between Tasks 2 and 5;
  `KeyCLI.parse/run/isEncryptedPEM` match between test and implementation.
- Known judgment call: `HostEditView` snapshots `libraryKeys` at sheet
  presentation (a fresh sheet re-reads the store), avoiding an observable
  key-store object for now — YAGNI until something needs live updates.
