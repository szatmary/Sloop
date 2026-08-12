# Shared SSH key library, synced via iCloud Keychain

_Approved 2026-08-11. Feature: a good way to get existing SSH private keys into
Sloop on iOS._

## Problem

The only way to get a private key into Sloop today is pasting PEM text into the
host editor, which stores it per-host in the device-local keychain. Keys that
several hosts share must be pasted once per host, per device, and getting the
PEM onto an iPad at all is awkward. The `AuthMethod.publicKey(name:)` model
already references keys by name; the storage and UI just never grew a library
behind it.

## Decisions (from brainstorming)

- **Import existing keys**, not on-device generation (generation may come later;
  see ROADMAP nice-to-haves).
- **Shared key library**: import once, reference from any host by name.
- **Synced via iCloud Keychain** (`kSecAttrSynchronizable`): end-to-end
  encrypted, appears in Sloop on all the user's Apple devices. This supersedes
  the ROADMAP note "secrets stay in the keychain, not iCloud" — iCloud Keychain
  IS the keychain, E2E-encrypted.
- **No QR import** (rejected: single QR codes cannot hold RSA-4096 PEMs; iCloud
  sync makes the Mac→iPad path automatic anyway).
- **Mac-side import is a CLI subcommand of the app binary** (approach A):
  a plain bash tool cannot write synchronizable items in the data-protection
  keychain or a shared access group — that requires a binary signed with the
  team holding the entitlement. Embedding the CLI in the already-signed app
  avoids a second target and its provisioning machinery.

## Design

### 1. SloopKit: `NamedKey` + `KeyStore`

- `NamedKey { name: String, privateKeyPEM: String, passphrase: String? }`,
  `name` unique within the library (e.g. `id_ed25519`).
- `protocol KeyStore: AnyObject` with `keys() -> [NamedKey]`,
  `key(named:) -> NamedKey?`, `setKey(_:) throws`, `removeKey(named:) throws`,
  mirroring `CredentialStore`. `InMemoryKeyStore` for tests.
- Connect-time resolution in `HostListModel.connect`: for
  `.publicKey(name:)`, look up the library by name first; if absent, fall back
  to the legacy per-host credential (the migration/compat tier, not error
  masking). Passwords remain per-host in `CredentialStore`.

### 2. App: `KeychainKeyStore`

- Generic-password items: account = key name, service =
  `org.szatmary.sloop.keys`, value = JSON-encoded `NamedKey` payload.
- `kSecAttrSynchronizable = true`; data-protection keychain on macOS
  (`kSecUseDataProtectionKeychain`); shared access group
  `KR5WZAG3UE.org.szatmary.sloop.shared`.
- Both app targets gain an entitlements file (XcodeGen `entitlements:`)
  declaring `keychain-access-groups` with that group.
- Keychain errors throw descriptive errors carrying the OSStatus; nothing is
  swallowed.
- Known limitation: the unsigned CI/nightly macOS build cannot use the shared
  synced keychain (the entitlement requires real signing). Dev builds and the
  eventual Developer-ID-signed release work. Password auth and the legacy
  per-host key tier are unaffected in unsigned builds.

### 3. macOS CLI: subcommand in the app binary

- Early in app `main`, before SwiftUI starts: if argv matches a subcommand,
  run it and exit.
  - `import-key <path> [--name <n>]` — name defaults to the file's basename;
    prompts for a passphrase when the PEM is encrypted (stored alongside the
    key, matching the existing `Credential` model).
  - `list-keys`
  - `remove-key <name>`
- `Scripts/sloop`: ~10-line bash wrapper that locates `Sloop.app` and execs
  the binary with the given args, so usage reads
  `sloop import-key ~/.ssh/id_ed25519`.

### 4. UI: key picker in `HostEditView`

- The *Private Key* pane becomes a picker over library key names, plus
  "Paste key…" which keeps the current TextEditor but saves into the library
  under a user-chosen name (default: the host alias).
- Saving sets `auth = .publicKey(name:)` with the selected name.
- Works identically on iOS and macOS.

### 5. Migration

- On first run, any host whose per-host credential holds a PEM has that key
  lifted into the library, named by the host's existing auth name (its alias).
  The per-host copy stays as the fallback tier. One-time and idempotent
  (re-running must not duplicate or overwrite newer library entries).

### 6. Testing

- SloopKit unit tests: `KeyStore` semantics, connect-time resolution (library
  hit, legacy fallback), migration idempotency — all against in-memory stores.
- `KeychainKeyStore` is exercised manually on-device; CI has no signed,
  entitled environment.
- App-level test for CLI argument parsing.

## Out of scope

- On-device key generation / Secure Enclave keys (ROADMAP nice-to-have).
- ssh-agent forwarding.
- Auto-linking `IdentityFile` references during SSH config import (worth a
  follow-up once the library exists).
- Multi-part/animated QR transfer.
