# Sloop — handoff & ship-readiness

_Last updated: 2026-08-08._

Sloop is a free, native terminal for Apple platforms (iPhone, iPad, Mac): an
SSH terminal with an optional Mosh (UDP/SSP) transport, modeled on "blink shell
with mosh." This document is the state of the project and the remaining path to
shipping — read it first.

## What's the honest status?

**Feature-complete for a v1, and everything builds + unit-tests green in CI on
iOS and macOS — but nothing has been run on real hardware yet.** CI proves the
code compiles, links, and passes SloopKit's unit tests. It does **not** prove a
live SSH or Mosh session actually works end-to-end. That runtime gap is the
biggest open risk and needs a human at a Mac with Xcode.

### Done and green in CI

- **Local echo terminal**, **SSH** (libssh2: connect, host-key TOFU + mismatch
  refusal, password & private-key auth, PTY shell, resize).
- **Mosh**: mosh 1.4.0's client core + protobuf cross-compiled to
  `mosh.xcframework`; an Objective-C++ bridge (`MoshBridge`) over
  `Network::Transport`; `MoshTransport` wired to per-host "Use Mosh" with
  graceful SSH fallback; roaming nudges on network-path change and app resume.
- **Terminal UX**: multi-session **tabs** (background tabs stay connected),
  **appearance settings** (font/theme/cursor), iPad/Mac **keyboard + menu
  commands** (⌘T/⌘W/⌘⇧[ ]), native macOS **Settings** window.
- **Host management**: keychain-backed credentials, host editor, **SSH config
  import/export** (`~/.ssh/config`), **shared key library** synced via iCloud
  Keychain with a Mac-side `sloop import-key` CLI (`Scripts/sloop`).
- **CI**: SloopKit unit tests, libssh2/protobuf/mosh xcframeworks, base app
  (iOS+macOS), SSH app (iOS+macOS), Mosh app (iOS+macOS), unsigned macOS
  Release + rolling `nightly` GitHub release. All required and green.

### NOT done / not verifiable here

- **Runtime validation** — no live SSH/Mosh session has been exercised. First
  device test is step 1 below.
- **Code signing / distribution** — the app is unsigned.
- **Marketing assets** (App Store screenshots). The app icon itself is DONE:
  `App/Sloop/Assets.xcassets` generated from the SVG master by
  `Scripts/generate-appicon.sh`.
- **iPad multi-window scenes** (in-app tabs cover most of the need).
- Nice-to-haves: SFTP, port forwarding, iCloud host sync, ssh-agent/Secure
  Enclave keys, Apple Watch command-runner.

## How to build & run (on a Mac with Xcode)

```sh
brew install xcodegen
# Pick a variant. libssh2/mosh xcframeworks come from Scripts/build-*.sh or the
# CI artifacts of the latest run.
xcodegen generate                       # base: local echo only, no SSH
xcodegen generate --spec project.ssh.yml   # + SSH  (needs Vendor/libssh2.xcframework)
xcodegen generate --spec project.mosh.yml  # + SSH + Mosh (needs libssh2 + mosh xcframeworks)
open Sloop.xcodeproj
# Schemes: Sloop_iOS, Sloop_macOS.  Tests: swift test  (SloopKit) and the
# Sloop_macOS scheme's SloopTests bundle.
```

**Signing note (since the key library landed):** the app targets now carry
`CODE_SIGN_ENTITLEMENTS` (`App/Sloop/Sloop.entitlements`, for the shared
keychain-access-group — see [Key library](#key-library) below), so a bare

```sh
xcodebuild -project Sloop.xcodeproj -scheme Sloop_macOS build
```

**fails** with *"requires a provisioning profile"* — there's no team selected
to sign the entitlement with. Three ways around it, depending on what you're
doing:

- **Interactive development** — open the project in Xcode (`open
  Sloop.xcodeproj`) and pick your team in the target's Signing & Capabilities
  tab once; subsequent Xcode builds and `xcodebuild` invocations reuse it.
- **Scripted/CI builds that need to run and use the app** — pass a team and
  let Xcode provision automatically:
  ```sh
  xcodebuild -project Sloop.xcodeproj -scheme Sloop_macOS \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team> CODE_SIGN_STYLE=Automatic build
  ```
- **Test-only builds that never touch the shared keychain** — skip signing
  entirely:
  ```sh
  xcodebuild test -project Sloop.xcodeproj -scheme Sloop_macOS \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  ```
  (Key-library keychain calls will fail at runtime with a descriptive error
  in an unsigned build — expected; see [Known limitations](#known-limitations)
  below.)

Prebuilt macOS app: the `nightly` GitHub release (refreshed on every push to
`main`). It's **ad-hoc signed but not notarized**, so Gatekeeper blocks the
download on first launch. To run it: right-click the app → **Open** → **Open**;
if macOS calls it *"damaged"*, clear the quarantine flag first:

```sh
xattr -cr /path/to/Sloop.app && open /path/to/Sloop.app
```

The "damaged" message is Gatekeeper on an unnotarized download, not a real
problem — it goes away with Developer ID signing + notarization (a ship step).

## The path to shipping (the real finish line)

1. **First device test.** Build `project.mosh.yml` on a Mac, run on a real
   iPhone/iPad and the Mac. Connect to a real SSH host, and to a host running
   `mosh-server`. Use the checklist below. Fix whatever the compile gate
   couldn't catch (layout, live I/O, rendering, roaming).
2. **App icons & launch assets** — DONE: `AppIcon.appiconset` (iOS single-size
   + full macOS set) via `Scripts/generate-appicon.sh`; verified in a local
   macOS build.
3. **Signing.** Apple Developer account → signing certs + provisioning; flip the
   Release build off `CODE_SIGNING_ALLOWED=NO`. Notarize the Mac build.
4. **Licensing files** — DONE: `LICENSE` (GPL-3.0) and `THIRD-PARTY-NOTICES.md`
   are in place. Keep this repo public so corresponding source is available.
   Confirm the GPL-3.0/App-Store posture in `Docs/LICENSING.md` is acceptable to
   you (it's viable; the residual risk is a Mosh copyright holder objecting).
5. **App Store Connect** — listing, screenshots, privacy questionnaire, submit.

## First-device-test checklist

- [ ] App launches on iPhone, iPad, and Mac; host list renders.
- [ ] **Local terminal** echoes input.
- [ ] **SSH password** login to a real host; shell is interactive; resize works.
- [x] **SSH key** login — RSA verified on an iPad against a live host
      (2026-08-17).
- [ ] **Host-key prompt** appears for an unknown host; mismatch is refused.
- [ ] **Mosh**: on a host with `mosh-server`, "Use Mosh" connects over UDP and
      renders; kill Wi-Fi→cellular and confirm it resumes (roaming).
- [ ] **Mosh fallback**: on a host without `mosh-server`, it falls back to SSH
      with the notice.
- [ ] **Tabs**: open several; switch; background tabs stay connected; ⌘T/⌘W/
      ⌘⇧[ ] on iPad/Mac.
- [ ] **Appearance**: font size / theme / cursor apply live; persist across
      relaunch; macOS ⌘, Settings.
- [ ] **SSH config**: import `~/.ssh/config`; export and re-import round-trips.

### Key types — required before release

Each supported key type must authenticate end to end, on device, against a
real server. Do not treat "the app connected" as covering all of them: the
crypto backend implements each key type separately, and Sloop has already
shipped a backend (mbedTLS) that could not parse Ed25519 keys at all while
RSA worked fine.

- [x] **RSA** (`ssh-rsa` key file, `rsa-sha2-*` signature) — verified on iPad,
      2026-08-17.
- [ ] **Ed25519** (`ssh-ed25519`) — NOT yet verified. Needs a host that
      authorizes an Ed25519 key; under OpenSSL the key parses, but no live
      session has used one.
- [ ] **ECDSA** (`ecdsa-sha2-nistp256`) — never exercised.
- [ ] **Passphrase-protected key** of any type — the passphrase path has never
      run on device.

**How to test this without fooling yourself.** `ssh -i <key> host` proves
nothing on its own: OpenSSH also offers your agent's keys and any
`IdentityFile` from `~/.ssh/config`, so a *different* key may be what
authenticates. This exact trap produced a false "Ed25519 works" reading during
the 2026-08-17 session. Always isolate:

```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/<key> user@host true   # only this key
ssh -v  -i ~/.ssh/<key> user@host true | grep 'Server accepts key'
```

The `Server accepts key:` line names the key that actually worked. Confirm it
is the one under test before recording a pass.

## Key library

A shared SSH key library, synced across devices via iCloud Keychain: import a
private key once and pick it from any host's editor on any of your signed-in
devices, instead of pasting or re-storing a PEM per host. Implementation:
`Sources/SloopKit/Model/KeyStore.swift` (the `KeyStore` protocol and the
`NamedKey` model — its JSON encoding is the synced wire format, see
`Tests/SloopKitTests/KeyStoreTests.swift`),
`Sources/SloopKit/Model/KeyLibrary.swift` (connect-time resolution + one-time
legacy migration), `App/Sloop/SSH/KeychainKeyStore.swift` (the keychain-backed
`KeyStore`, in the shared access group), and the picker in
`App/Sloop/Views/HostEditView.swift`.

**Verified on real hardware (2026-08-17):** a key imported on a Mac with
`sloop import-key` (Debug build signed with team `KR5WZAG3UE`) propagated
through iCloud Keychain and appeared in the key picker on an iPad (9th gen,
iPadOS 26.6) running a signed Debug build. This confirms the end-to-end path:
the synchronizable keychain item, the shared access group, and — the part
automatic signing had to arrange on its own — the iOS provisioning profile
carrying the keychain-sharing capability. Propagation is not instant: the
iPad showed nothing until it had been awake and network-connected for a
while after the import. An empty picker shortly after an import is most
likely sync latency, not a failure. **Still unverified:** an actual SSH
login authenticated by a library key (blocked on the same live-SSH gap the
rest of the app has).

### The `sloop` CLI

The Mac app binary doubles as a CLI for managing the library from the
terminal — quicker than pasting a PEM into the host editor for every import.
It lives *inside* the app binary (`App/Sloop/KeyCLI.swift`), not as a
separate executable, because writing the shared, iCloud-synced keychain item
requires the app's own code signature and entitlements; a standalone script
can't do that.

```
sloop import-key <path> [--name <name>] [--force]
sloop list-keys
sloop remove-key <name>
```

- `import-key` reads a PEM from `<path>`, prompting for a passphrase if the
  key is encrypted. The library name defaults to the file's basename; pass
  `--name` to choose one explicitly. If that name already exists in the
  library, the import is **refused** (never silently overwritten — the
  library syncs to every device) unless you pass `--force`.
- `list-keys` prints every key name in the library (and whether it has a
  stored passphrase).
- `remove-key <name>` deletes a key from the library. Note this only removes
  the library entry: a host that predates the key library may still have its
  own legacy per-host copy of the same key material, which `remove-key`
  leaves untouched (see Known limitations below).

Run it via `Scripts/sloop`, a thin wrapper that execs into the app binary. It
looks for `Sloop.app` or `Sloop_macOS.app` (a local build keeps the scheme
name; a packaged release is renamed) in `/Applications` and
`~/Applications`. Point `SLOOP_APP` at a different `.app` bundle or straight
at the binary to override the search — handy when your build is still
sitting in DerivedData:

```sh
SLOOP_APP=~/Library/Developer/Xcode/DerivedData/Sloop-*/Build/Products/Debug/Sloop_macOS.app \
  Scripts/sloop list-keys
```

The CLI (and the app's own key picker) needs a **properly signed build** —
one whose code signature carries the keychain-access-group entitlement for
the shared group, from a team matching the hardcoded prefix in
`KeychainKeyStore.sharedAccessGroup`. See `Docs/SIGNING.md` and the signing
note under "How to build & run" above. An unsigned or wrongly-signed build
fails every key-library operation with a descriptive keychain error, not
silence.

### Known limitations

Two behaviors below are deliberate trade-offs, not bugs — flagging them here
because fixing either needs a design decision this document doesn't make on
your behalf:

- **The ad-hoc-signed nightly build can't do key auth at all.** Ad-hoc
  signing (`codesign --sign -`, what the `nightly` GitHub release uses) can't
  carry a real keychain-access-group entitlement, so every shared-keychain
  call in that build fails. There is no per-host fallback key writer
  anymore — the old per-host `Credential`-based key storage still exists as
  the legacy *read* fallback (`KeyLibrary.credential`), but nothing writes to
  it going forward, so the paste-a-key flow in the host editor throws on an
  ad-hoc build. **Password auth is unaffected** and works on any build.
  Configuring key auth requires a properly signed build (see above).
- **Migration can make one device's key shadow another's.** Legacy
  migration (`KeyLibrary.migrate`) names each newly-lifted library key after
  the *host's alias*, not anything intrinsically unique. Hosts are
  local-only (never synced); library keys sync via iCloud Keychain. So if two
  devices each have a pre-migration host with the same alias but different
  key material (e.g. both call a host "prod" but used different keys before
  the library existed), migration on each device creates a library entry
  named "prod" — and because `migrate` never overwrites an existing entry,
  whichever device's sync lands first wins, and the other device's "prod"
  host silently starts using the wrong key. If this applies to you: rename
  the affected hosts to be unique before they migrate, or re-pick each
  host's key explicitly in the editor afterward.

## Where things live

- `Sources/SloopKit/` — Foundation-only core (models, transports' Swift side,
  parsers). Unit-tested; Linux/CI-buildable.
- `App/Sloop/` — the SwiftUI app + SwiftTerm glue + the SSH/Mosh native bridges.
- `Scripts/build-*.sh` — cross-compile libssh2 / protobuf / mosh xcframeworks.
- `project*.yml` — XcodeGen specs (base / `.ssh` / `.mosh`).
- `Docs/` — `ROADMAP`, `SSH`, `MOSH`, `LICENSING`, `PROGRESS`, and this file.
