# Roadmap

Target: a full-featured mobile shell — SSH + Mosh — across iPhone, iPad, Mac, and tvOS.
Sequenced so something runs at every step and the hardest piece (Mosh) lands on
top of a working SSH terminal rather than first.

## M0 — Scaffold ✅ (this commit)

- SloopKit core: `Transport`, `EchoTransport`, `TerminalSession`, `Host`,
  `HostStore`, `Credential`, `LibSSH2Transport` skeleton, `MoshBootstrap`.
- SwiftUI multiplatform app wrapping SwiftTerm; host list + editor.
- **Local terminal** (echo) runs on device/simulator.
- Unit tests for echo, Mosh handshake parsing, host persistence.

## M1 — SSH terminal ✅

- [x] Vendor libssh2 as an `.xcframework` (see `Docs/SSH.md`) — built in CI.
- [x] Implement `LibSSH2Transport`: TCP connect, handshake, host-key check,
      auth, PTY shell channel, read/write pump, `resize`. Compiles + links in CI.
- [x] `KnownHostsStore` with trust-on-first-use + mismatch refusal (unit-tested).
- [x] Keychain-backed `CredentialStore`; password entry in the host editor.
- [x] Trust-on-first-use **prompt** in the UI (`HostKeyPromptView` / `HostKeyPrompter`).
- [x] Private-key (PEM + passphrase) auth entry in the host editor.

## M2 — Keyboard & UX (in progress)

- [x] External-keyboard shortcuts (arrows, Ctrl/Alt/Meta chords) via key commands.
- [x] Sticky-modifier smart-keys bar (Ctrl/Alt held for the next key).
- [ ] Font, color scheme, and cursor settings.
- [ ] iPad multi-window tabs.

## M3 — Mosh ✅

- [x] Cross-compile the Mosh client for arm64 (device/sim) + macOS — `mosh.xcframework`
      built in CI (tvOS deferred with the app). See `Docs/MOSH.md`.
- [x] SSH bootstrap: run `mosh-server`, parse `MOSH CONNECT` (`MoshBootstrap`).
- [x] `MoshTransport: Transport` over UDP with SSP (`MoshBridge` C++ shim);
      roaming across network changes and app resume.
- [x] Per-host "Use Mosh" honored end-to-end (`MoshOrSSHTransport`, with graceful
      SSH fallback when `mosh-server` is missing).
- [ ] Runtime validation against a live `mosh-server` (CI proves it builds/links).

## M4 — Ship

- [ ] Resolve licensing (`Docs/LICENSING.md`) before App Store submission.
- [ ] App icons, launch, tvOS focus model, Mac menu commands.
- [ ] Background-connection handling and reconnect polish.

## Deferred

- **tvOS app** — blocked on SwiftTerm: its UIKit terminal views don't compile
  for tvOS (the `iOS/` sources reference a `TerminalView` type not defined
  there). SloopKit already targets tvOS, so revisit once SwiftTerm supports it
  or a tvOS renderer is swapped in. iOS + macOS ship first.

## Nice-to-have

- iCloud host sync (secrets stay in the keychain, not iCloud).
- SFTP / file transfer.
- Port forwarding.
- `ssh-agent` / Secure Enclave keys.
- **`CommandRunner`** — non-interactive SSH exec (`{stdout, stderr, exitStatus}`)
  for saved one-shot commands on iOS/Mac. Also the foundation for a watch app.
- **Apple Watch** — an ops "command runner" (not a terminal), ideally driven
  through the paired iPhone via WatchConnectivity. See `Docs/WATCH.md`.
- **Tip jar** — a non-consumable "Leave a Tip" IAP that unlocks a Thank-You page
  (❤️); no features gated. Scaffolded in `App/Sloop/Store`. See `Docs/TIPJAR.md`.
