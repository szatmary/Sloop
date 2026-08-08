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
  import/export** (`~/.ssh/config`).
- **CI**: SloopKit unit tests, libssh2/protobuf/mosh xcframeworks, base app
  (iOS+macOS), SSH app (iOS+macOS), Mosh app (iOS+macOS), unsigned macOS
  Release + rolling `nightly` GitHub release. All required and green.

### NOT done / not verifiable here

- **Runtime validation** — no live SSH/Mosh session has been exercised. First
  device test is step 1 below.
- **Code signing / distribution** — the app is unsigned.
- **App icons & marketing assets.**
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
2. **App icons & launch assets.** Add an `AppIcon` asset set; verify launch.
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
- [ ] **SSH key** login (paste PEM or import a key file).
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

## Where things live

- `Sources/SloopKit/` — Foundation-only core (models, transports' Swift side,
  parsers). Unit-tested; Linux/CI-buildable.
- `App/Sloop/` — the SwiftUI app + SwiftTerm glue + the SSH/Mosh native bridges.
- `Scripts/build-*.sh` — cross-compile libssh2 / protobuf / mosh xcframeworks.
- `project*.yml` — XcodeGen specs (base / `.ssh` / `.mosh`).
- `Docs/` — `ROADMAP`, `SSH`, `MOSH`, `LICENSING`, `PROGRESS`, and this file.
