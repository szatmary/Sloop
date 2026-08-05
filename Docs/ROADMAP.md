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

## M1 — SSH terminal (in progress)

- [ ] Vendor libssh2 as an `.xcframework` (see `Docs/SSH.md`). ← only remaining blocker to a live SSH build
- [x] Implement `LibSSH2Transport`: TCP connect, handshake, host-key check,
      auth, PTY shell channel, read/write pump, `resize`. *(written; needs a compile pass)*
- [x] `KnownHostsStore` with trust-on-first-use + mismatch refusal (unit-tested).
- [x] Keychain-backed `CredentialStore`; password entry in the host editor.
- [ ] Trust-on-first-use **prompt** in the UI (today unknown keys auto-accept).
- [ ] Private-key auth entry in the editor (transport already supports keys).

## M2 — Keyboard & UX

- [ ] External-keyboard shortcuts (arrows, Ctrl/Alt/Meta chords) via key commands.
- [ ] Sticky-modifier smart-keys bar (Ctrl/Alt held for the next key).
- [ ] Font, color scheme, and cursor settings; iPad multi-window tabs.

## M3 — Mosh

- [ ] Cross-compile the Mosh client for arm64 (device/sim), macOS, tvOS
      (see `Docs/MOSH.md`).
- [ ] SSH bootstrap: run `mosh-server`, parse `MOSH CONNECT` (`MoshBootstrap`).
- [ ] `MoshTransport: Transport` over UDP with SSP; reconnect across network
      changes and app suspension.
- [ ] Per-host "Use Mosh" honored end-to-end.

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
