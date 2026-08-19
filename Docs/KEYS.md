# The key library

A shared SSH key library, synced across devices via iCloud Keychain: import a
private key once and pick it from any host's editor on any of your signed-in
devices, instead of pasting or re-storing a PEM per host.

## Where it lives

| Piece | File |
| --- | --- |
| `KeyStore` protocol and the `NamedKey` model | [`Sources/SloopKit/Model/KeyStore.swift`](../Sources/SloopKit/Model/KeyStore.swift) |
| Connect-time resolution + one-time legacy migration | [`Sources/SloopKit/Model/KeyLibrary.swift`](../Sources/SloopKit/Model/KeyLibrary.swift) |
| The keychain-backed store, in the shared access group | [`App/SloopSSH/KeychainKeyStore.swift`](../App/SloopSSH/KeychainKeyStore.swift) |
| The picker | [`App/Sloop/Views/HostEditView.swift`](../App/Sloop/Views/HostEditView.swift) |

`NamedKey`'s JSON encoding is the synced wire format — changing it changes what
every other device reads. It is pinned in
[`Tests/SloopKitTests/KeyStoreTests.swift`](../Tests/SloopKitTests/KeyStoreTests.swift).

Keychain accessibility and the Secure Enclave question are covered in
[`LAUNCH.md`](LAUNCH.md) §7, including one open bug about the File Provider
extension reading library keys on a locked device.

## Verified on real hardware (2026-08-17)

A key imported on a Mac with `sloop import-key` (Debug build signed with team
`KR5WZAG3UE`) propagated through iCloud Keychain and appeared in the key picker
on an iPad (9th gen, iPadOS 26.6) running a signed Debug build. That confirms
the end-to-end path: the synchronizable keychain item, the shared access group,
and — the part automatic signing had to arrange on its own — the iOS
provisioning profile carrying the keychain-sharing capability.

Propagation is not instant. The iPad showed nothing until it had been awake and
network-connected for a while after the import. **An empty picker shortly after
an import is most likely sync latency, not a failure.**

Still unverified: an actual SSH login authenticated by a library key. See
[`LAUNCH.md`](LAUNCH.md) §6.

## The `sloop` CLI

The Mac app binary doubles as a CLI for managing the library from the terminal —
quicker than pasting a PEM into the host editor for every import. It lives
*inside* the app binary ([`App/Sloop/KeyCLI.swift`](../App/Sloop/KeyCLI.swift)),
not as a separate executable, because writing the shared, iCloud-synced keychain
item requires the app's own code signature and entitlements; a standalone script
cannot do that.

```
sloop import-key <path> [--name <name>] [--force]
sloop list-keys
sloop remove-key <name>
```

- `import-key` reads a PEM from `<path>`, prompting for a passphrase if the key
  is encrypted. The library name defaults to the file's basename; pass `--name`
  to choose one explicitly. If that name already exists the import is
  **refused** — never silently overwritten, because the library syncs to every
  device — unless you pass `--force`.
- `list-keys` prints every key name in the library, and whether it has a stored
  passphrase.
- `remove-key <name>` deletes a library entry. Note that this only removes the
  *library* entry: a host predating the key library may still have its own
  legacy per-host copy of the same key material, which `remove-key` leaves
  untouched.

Run it via `Scripts/sloop`, a thin wrapper that execs into the app binary. It
looks for `Sloop.app` or `Sloop_macOS.app` (a local build keeps the scheme name;
a packaged release is renamed) in `/Applications` and `~/Applications`. Point
`SLOOP_APP` at a different `.app` bundle or straight at the binary to override
the search — handy when your build is still in DerivedData:

```sh
SLOOP_APP=~/Library/Developer/Xcode/DerivedData/Sloop-*/Build/Products/Debug/Sloop_macOS.app \
  Scripts/sloop list-keys
```

The CLI and the app's key picker both need a **properly signed build** — one
whose signature carries the keychain-access-group entitlement for the shared
group, from a team matching the hardcoded prefix in
`KeychainKeyStore.sharedAccessGroup`. See [`SIGNING.md`](SIGNING.md). An
unsigned or wrongly-signed build fails every key-library operation with a
descriptive keychain error, not silence.

## Known limitations

Both are deliberate trade-offs. Fixing either needs a design decision.

**The ad-hoc-signed nightly build cannot do key auth at all.** Ad-hoc signing
(`codesign --sign -`, what the `nightly` GitHub release uses) cannot carry a
real keychain-access-group entitlement, so every shared-keychain call in that
build fails. There is no per-host fallback key writer anymore — the old
per-host `Credential`-based storage survives as the legacy *read* fallback
(`KeyLibrary.credential`), but nothing writes to it, so the paste-a-key flow in
the host editor throws on an ad-hoc build. **Password auth is unaffected** and
works on any build.

**Migration can make one device's key shadow another's.** `KeyLibrary.migrate`
names each newly-lifted library key after the *host's alias*, not anything
intrinsically unique. Hosts are local-only; library keys sync. So if two devices
each have a pre-migration host with the same alias but different key material —
both called "prod", each using a different key before the library existed —
migration on each device creates a library entry named "prod". Because
`migrate` never overwrites an existing entry, whichever device's sync lands
first wins, and the other device's "prod" host silently starts using the wrong
key.

If that applies to you: rename the affected hosts to be unique before they
migrate, or re-pick each host's key explicitly in the editor afterward.
