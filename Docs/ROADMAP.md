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
- [x] Dismissible keyboard — a `⌨︎↓` key and a floating pill that replaces the
      smart-keys bar while the keyboard is down, so the bar stops reserving
      44pt it isn't using.
- [x] Custom compact keyboard — `KeyboardLayout` resolves a terminal-shaped
      layout per device (symbol row on iPad, drag-up symbols on iPhone),
      installed via SwiftTerm's `inputView`. Chosen in Terminal Settings;
      Standard remains the default. Implementation is complete and
      unit-tested, but two things remain unverified: no on-device testing has
      been done (this work was done without hardware available), and the
      compact layout's row heights are still unmeasured placeholders rather
      than values checked against real touch targets. Spec:
      `Docs/superpowers/specs/2026-08-17-terminal-rows-design.md`.
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

## M4 — Ship (the remaining finish line — see `Docs/HANDOFF.md`)

- [x] Mac menu commands (Terminal menu: new/close/cycle tabs) + macOS Settings.
- [x] Licensing files: `LICENSE` (GPL-3.0) + `THIRD-PARTY-NOTICES.md`. The
      GPL-3.0/App-Store posture is decided (`Docs/LICENSING.md`); only your
      sign-off on the residual risk remains.
- [ ] **Runtime validation on real hardware** — first device test (biggest
      open risk; nothing has run live yet). Checklist in `Docs/HANDOFF.md`.
- [x] App icon: `AppIcon.appiconset` generated from the SVG master
      (`Scripts/generate-appicon.sh`); launch screen is system-generated.
- [ ] Code signing + notarization (currently unsigned).
- [ ] App Store Connect listing + submission.
- [ ] Background-connection handling and reconnect polish (Mosh roaming exists;
      exercise it on-device).

## Deferred

- **tvOS app** — blocked on SwiftTerm: its UIKit terminal views don't compile
  for tvOS (the `iOS/` sources reference a `TerminalView` type not defined
  there). SloopKit already targets tvOS, so revisit once SwiftTerm supports it
  or a tvOS renderer is swapped in. iOS + macOS ship first.

## Nice-to-have

- iCloud host sync (the host list itself is still local-only; key material
  already syncs today via iCloud Keychain, E2E-encrypted, as part of the
  shared key library below — the host list is what's not yet synced).
- **On-connect command** — a per-host command run automatically once the shell
  is up, so a host can drop you straight into a session rather than a bare
  prompt. The motivating case is `tmux attach || tmux new` (or `tmux a`):
  reconnecting to the same multiplexed session is the normal workflow on a
  phone or tablet, where the network drops constantly. Worth deciding whether
  it runs in the PTY (visible, and the user can Ctrl-C out of it) or as an
  exec channel, and whether a failed command should leave the plain shell.
- SFTP / file transfer.
- Port forwarding.
- ~~Key management~~ → DONE: shared key library synced via iCloud Keychain;
  `sloop import-key` CLI on the Mac (embedded in the app binary). Spec:
  `Docs/superpowers/specs/2026-08-11-key-library-design.md`.
- `ssh-agent` / Secure Enclave keys.
- **`CommandRunner`** — non-interactive SSH exec (`{stdout, stderr, exitStatus}`)
  for saved one-shot commands on iOS/Mac. Also the foundation for a watch app.
- **Apple Watch** — an ops "command runner" (not a terminal), ideally driven
  through the paired iPhone via WatchConnectivity. See `Docs/WATCH.md`.
- **Tip jar** — a non-consumable "Leave a Tip" IAP that unlocks a Thank-You page
  (❤️); no features gated. Scaffolded in `App/Sloop/Store`. See `Docs/TIPJAR.md`.
