# Roadmap

Target: a full-featured mobile shell — SSH + Mosh — across iPhone, iPad, Mac, and tvOS.
Sequenced so something runs at every step and the hardest piece (Mosh) lands on
top of a working SSH terminal rather than first.

## M0 — Scaffold ✅ (this commit)

- SloopKit core: `Transport`, `TerminalSession`, `Host`, `HostStore`,
  `Credential`, `LibSSH2Transport` skeleton, `MoshBootstrap`.
- SwiftUI multiplatform app wrapping SwiftTerm; host list + editor.
- ~~**Local terminal** (echo) runs on device/simulator~~ — removed once SSH and
  Mosh both worked: a fake shell that echoed keystrokes and connected to
  nothing was a dead end, not a feature (`Drop the local echo terminal`).
- Unit tests for Mosh handshake parsing and host persistence.

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
- [x] Font, color scheme, and cursor settings (`TerminalSettingsView`).
- [x] Tabs, and a home screen that lists open sessions so you can jump to one.
- [x] Dismissible keyboard — a `⌨︎↓` key and a floating pill that replaces the
      smart-keys bar while the keyboard is down, so the bar stops reserving
      44pt it isn't using.
- [x] Custom compact keyboard — `KeyboardLayout` resolves a terminal-shaped
      layout per device (symbol row on iPad, drag-up symbols on iPhone),
      installed via SwiftTerm's `inputView`. Chosen in Terminal Settings;
      Standard remains the default. Spec:
      `Docs/superpowers/specs/2026-08-17-terminal-rows-design.md`.
- [ ] On-device verification of the dismissible and compact keyboards above —
      built and tested in the simulator only. The compact layout's row heights
      are still unmeasured placeholders rather than values checked against real
      touch targets.
- [ ] iPad multi-window tabs (separate windows, not the in-app tabs above).

## M3 — Mosh ✅

- [x] Cross-compile the Mosh client for arm64 (device/sim) + macOS — `mosh.xcframework`
      built in CI (tvOS deferred with the app). See `Docs/MOSH.md`.
- [x] SSH bootstrap: run `mosh-server`, parse `MOSH CONNECT` (`MoshBootstrap`).
- [x] `MoshTransport: Transport` over UDP with SSP (`MoshBridge` C++ shim);
      roaming across network changes and app resume.
- [x] Per-host "Use Mosh" honored end-to-end (`MoshOrSSHTransport`, with graceful
      SSH fallback when `mosh-server` is missing).
- [x] Runtime validation against a live `mosh-server`. It found two bugs no test
      could: a frozen clock that sent exactly one packet per session, and a "C"
      locale that truncated every multi-byte character to its lead byte.

## M4 — Ship (the remaining finish line — see `Docs/HANDOFF.md`)

- [x] Mac menu commands (Terminal menu: new/close/cycle tabs) + macOS Settings.
- [x] Licensing files: `LICENSE` (GPL-3.0) + `THIRD-PARTY-NOTICES.md`. The
      GPL-3.0/App-Store posture is decided (`Docs/LICENSING.md`); only your
      sign-off on the residual risk remains.
- [ ] **Runtime validation on real hardware** — SSH, Mosh, and a Cloudflare
      Access tunnel all connect from an iPad. Remaining:
      Ed25519/ECDSA/passphrase-protected keys, and Mosh roaming across
      Wi-Fi→cellular. Checklist in `Docs/HANDOFF.md`.
- [x] App icon: `AppIcon.appiconset` generated from the SVG master
      (`Scripts/generate-appicon.sh`); launch screen is system-generated.
- [ ] Code signing + notarization. Releases are ad-hoc signed today;
      `Scripts/sign-release.sh` and `Docs/SIGNING.md` cover the Developer ID
      path, which needs notarytool credentials stored once.
- [ ] App Store Connect listing + submission.
- [ ] Background-connection handling and reconnect polish (Mosh roaming exists;
      exercise it on-device).

## Tunnels — Cloudflare Access ✅, Tailscale next

- [x] `Dialer` seam (`TCPDialer` wraps the existing direct-connect path, no
      behavior change) + `SSHHost.connectionMethod`. See
      [`Docs/ARCHITECTURE.md`](ARCHITECTURE.md).
- [x] Cloudflare Access: native WebSocket carrier (`CloudflareAccessDialer`),
      browser SSO (`AccessLoginView`), Keychain-backed token store. SSH-only —
      Mosh needs UDP, which the tunnel can't carry. Unit-tested; **not yet
      run against a real Cloudflare Tunnel** — see the checklist in
      [`Docs/HANDOFF.md`](HANDOFF.md).
- [ ] Tailscale via embedded TailscaleKit — separate plan, gated on a
      real-device smoke test of the vendored framework before any integration
      work starts (a past iOS sandbox failure in the same code path,
      tailscale/tailscale#15410, is closed but unverified against the current
      release). See
      [`Docs/superpowers/specs/2026-08-12-tunnel-integrations-design.md`](superpowers/specs/2026-08-12-tunnel-integrations-design.md).

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
- ~~On-connect command~~ → DONE: a per-host command (`SSHHost.onConnectCommand`,
  set in the host editor) typed into the PTY as ordinary input once it opens,
  and again on every reconnect — the motivating case is `tmux attach || tmux
  new`, so a dropped connection lands back in the same session instead of a
  bare prompt. Offered as a suggestion above the keyboard, and visible in the
  terminal, so Ctrl-C leaves the plain shell.
- ~~Custom compact keyboard~~ → DONE in M2: a terminal-shaped keyboard via
  SwiftTerm's settable `inputView`, folding the smart-keys bar into the keyboard
  rather than stacking a row above it. The software keyboard is the largest
  consumer of screen space, and iPadOS's own floating keyboard cannot be invoked
  programmatically, so the only real fix was owning the keyboard.
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
- ~~Sloop as its own tailnet node~~ → DONE: `libtailscale` (tsnet) is vendored
  as `Vendor/libtailscale.xcframework` and Sloop joins the tailnet itself — no
  Tailscale app, and no system VPN slot, which on iOS is the difference between
  Tailscale and every other VPN the user might want. Verified on an iPad,
  2026-08-18, including the device-authorization sheet. The spec's risk gate
  (tailscale/tailscale#15410, `os.Executable()` failing inside the iOS sandbox)
  turned out not to bite. Its own build variant, `project.tailscale.yml`: the Go
  archive is most of 23 MB.
- **Jump hosts / ProxyJump** — `SSHConfigParser` reads exactly four keys
  (`Host`, `HostName`, `Port`, `User`). Anyone whose infrastructure sits behind
  a bastion cannot connect at all, and an imported `~/.ssh/config` silently
  drops the `ProxyJump`/`ProxyCommand` line that made it work on the desktop.
  Blink, Termius and Prompt all support it. Adjacent to the Cloudflare Access
  tunnel work, which is the same shape of problem: reaching a host you cannot
  route to directly.
- ~~Agent forwarding~~ → DONE: a host picks which library keys its forwarded
  agent may expose (`SSHHost.forwardedKeys`, empty means off); the host editor
  lists the library with a toggle per key and states plainly what forwarding
  means (anyone with root on the host can use the key while the connection is
  open; every use prompts on-device first). Covered by unit tests, including
  concurrent forwarded-agent clients — **but never exercised against a real
  remote host.** Nothing in the on-device checklist (`Docs/HANDOFF.md`) has
  confirmed a live `ssh-add -l`, a real approve/deny round trip, or two
  concurrent `ssh` calls against actual `sshd`. Separately, unrelated to this
  feature: `AuthMethod.agent` (`Sources/SloopKit/Model/SSHHost.swift`) is
  still dead scaffolding with zero references anywhere in the codebase — this
  feature is built on `forwardedKeys`/`forwardsAgent`, not that case. Removed
  on the separate, unmerged `ssh-url-and-agent` branch; left in place here.
- **SFTP / file transfer** — and the version that actually matters is a
  `FileProvider` extension, so a remote host appears in Files.app and any app
  can open and save to it. Secure ShellFish built its whole identity on that;
  a transfer sheet inside the app is a much smaller feature.
- **Port forwarding** — local forwarding especially: reaching a remote dev
  server from mobile Safari.
- **`ssh://` URL scheme** — no `CFBundleURLTypes` in `project.yml`, so tapping
  an `ssh://user@host` link does nothing. It is how people share hosts, and it
  is close to free.
- **Command suggestions** — designed and planned, not yet built. Instead of a
  curated snippet library (which every competitor ships and nobody maintains),
  Sloop reads the terminal *screen* and lets an on-device model pick the
  commands out of it, so the history is the snippet library and there is
  nothing to curate. Reading the screen rather than the keystrokes is also what
  makes it safe: a password is never echoed, so it is structurally absent
  rather than filtered out. The model may invent commands, not just recall
  them, so suggestions insert and never execute, and invented ones are marked
  as such. On-device only — nothing leaves the phone. Requires iOS 26 with
  Apple Intelligence; a mode for older devices is still open.
  Spec: `Docs/superpowers/specs/2026-08-18-command-suggestions-design.md`.
  Plan: `Docs/superpowers/plans/2026-08-18-command-suggestions.md` (7 tasks).
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
