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
- **Carry the typed error into `ConnectionState`** — `TerminalController.wire`
  stringifies at the boundary (`error?.localizedDescription`) and stores prose
  in `.disconnected(reason:)`, so nothing downstream can tell a rejected
  credential from a dropped Wi-Fi link from a tunnel that wants a browser
  login. Every recovery affordance needs that distinction: an auth failure
  should offer to fix the host's credential, a Cloudflare Access session that
  expired should re-present the login sheet, and a network drop should just
  reconnect. Today all three render as the same grey text with a Reconnect
  button. This is the same lesson as `SSHError.authenticationFailed(String)`
  one layer up — a failure reported honestly but indistinguishably costs hours
  to diagnose and cannot be recovered from automatically. It wants its own
  piece of work: it changes `ConnectionState`, which both the terminal UI and
  the tunnel work build on. (Found by the Cloudflare Access session, 2026-08.)
- **On-connect command** — a per-host command run automatically once the shell
  is up, so a host can drop you straight into a session rather than a bare
  prompt. The motivating case is `tmux attach || tmux new` (or `tmux a`):
  reconnecting to the same multiplexed session is the normal workflow on a
  phone or tablet, where the network drops constantly. Worth deciding whether
  it runs in the PTY (visible, and the user can Ctrl-C out of it) or as an
  exec channel, and whether a failed command should leave the plain shell.
- **Custom compact keyboard** — replace the system keyboard with a
  terminal-shaped one via SwiftTerm's settable `inputView`, folding today's
  smart-keys bar into the keyboard instead of stacking a row above it. The
  software keyboard is the single largest consumer of screen space, so this is
  the biggest remaining win for visible rows. iPadOS's own floating keyboard
  (pinch to shrink) helps today but cannot be invoked programmatically — there
  is no public API — so a real fix means owning the keyboard. Design work:
  key sizes, symbol/digit layers, portrait vs landscape.
- **Connection timeouts and keepalives** — there are none. `grep -ri
  "timeout\|keepalive\|ServerAlive"` over `Sources/` and `App/` returns nothing,
  so an unreachable host hangs on `connect()` with no deadline and no way for
  the user to tell "still trying" from "never going to work", and a connection
  that dies silently (NAT timeout, sleeping laptop, dropped VPN) is never
  detected — the terminal just stops responding. Wants a connect timeout, a
  read/write deadline, and `ServerAliveInterval`-style keepalives, surfaced
  through `ConnectionState` so the UI can say which one fired. Arguably the
  most-felt gap on this list: it costs nothing to hit and every mobile user
  hits it.
- **Jump hosts / ProxyJump** — `SSHConfigParser` reads exactly four keys
  (`Host`, `HostName`, `Port`, `User`). Anyone whose infrastructure sits behind
  a bastion cannot connect at all, and an imported `~/.ssh/config` silently
  drops the `ProxyJump`/`ProxyCommand` line that made it work on the desktop.
  Blink, Termius and Prompt all support it. Adjacent to the Cloudflare Access
  tunnel work, which is the same shape of problem: reaching a host you cannot
  route to directly.
- **Agent forwarding, and `ssh-agent` generally** — `AuthMethod.agent` is
  declared in `SSHHost.swift` but has **no implementation anywhere** in the SSH
  layer or the UI; it currently reads as a supported auth method that silently
  isn't one. Either implement it or delete the case. Forwarding specifically is
  what lets `git pull` on the remote use the key held on the phone, which is
  one of the most common reasons to SSH from a phone at all.
- **SFTP / file transfer** — and the version that actually matters is a
  `FileProvider` extension, so a remote host appears in Files.app and any app
  can open and save to it. Secure ShellFish built its whole identity on that;
  a transfer sheet inside the app is a much smaller feature.
- **Port forwarding** — local forwarding especially: reaching a remote dev
  server from mobile Safari.
- **`ssh://` URL scheme** — no `CFBundleURLTypes` in `project.yml`, so tapping
  an `ssh://user@host` link does nothing. It is how people share hosts, and it
  is close to free.
- **Snippets, or something better than snippets** — every competitor ships a
  saved-command library (Prompt calls them Clips; Blink and Termius call them
  Snippets) because typing `docker compose -f prod.yml logs -f --tail=100 api`
  on a phone is miserable. That is the same problem the compact keyboard
  attacks, from the other end. **Open question, not yet decided:** whether the
  answer is a plain saved-command list or something that suggests commands.
  If it suggests, the design questions are which model and where it runs —
  Apple's on-device Foundation Models framework needs no key, no network and
  no privacy story, while a hosted model is far more capable but means terminal
  context leaving the device, which for a shell client is a much bigger promise
  than it looks. Decide the privacy posture before the model.
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
