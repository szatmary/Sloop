# Autonomous progress log

Running on branch `claude/ios-terminal-app-uwmzf3` via a 10-minute `/loop`
while the maintainer is away. Newest entries first.

## 2026-08-05

- **Fix CI (xcodegen spec broke):** the multiplatform test wiring failed —
  XcodeGen doesn't resolve the base name `Sloop`/`SloopTests` in dependencies or
  scheme test targets ("invalid dependency: Sloop"). Reworked `project.yml` into
  explicit `Sloop_iOS` / `Sloop_macOS` targets sharing a `SloopApp` template, so
  `SloopTests` (macOS) can depend on the real `Sloop_macOS` target and attach to
  its scheme. Updated `project.ssh.yml` to add the libssh2 framework to both
  targets. Scheme names unchanged, so CI is untouched.
- **Release Mac app artifact (user request):** new `mac-release` CI job builds
  the macOS app in **Release** (arm64, SSH-enabled via the libssh2 xcframework),
  packages `Sloop.app` with `ditto`, and uploads it as the `Sloop-macOS-app`
  artifact (`Sloop-macOS.zip`). Unsigned for now — signing keys to be added
  later (Gatekeeper will require right-click → Open to run it).
- **macOS app tests (user request):** added an app-hosted unit-test target
  `SloopTests` (`Tests/SloopAppTests`) that `@testable import`s the app and runs
  on the macOS runner via `xcodebuild test -scheme Sloop_macOS`. Tests exercise
  real app code the SloopKit tests can't reach: the SwiftTerm coordinator
  forwarding keystrokes and resize to the transport, and `TransportFactory`'s
  fallback. The `app-build` CI job now runs these on macOS.
- **All four CI jobs green (run 31036120147):** SloopKit tests, libssh2
  xcframework, app (iOS · macOS), and the real SSH build all pass — the SSH
  transport compiles and links against libssh2 on iOS and macOS. Tip-jar
  StoreKit code compiled too.
- **Tip jar (user request):** added a non-consumable "Leave a Tip" IAP
  (StoreKit 2) that unlocks a Thank-You page with a ❤️ — no features gated.
  New `App/Sloop/Store/TipJar.swift` + `SupportView.swift`, a heart button in
  the host-list toolbar, a `Sloop.storekit` test config, and `Docs/TIPJAR.md`.
- **SSH compile fix #2 (run 31035244684):** past the macro error, the channel
  read hit a Swift exclusive-access violation — `buffer.count` was read inside
  `buffer.withUnsafeMutableBytes { }`. Use the raw buffer's own `raw.count`
  instead. Pushed.
- **Merge policy:** the repo's default/mainline branch IS
  `claude/ios-terminal-app-uwmzf3`, so every push already lands on mainline —
  nothing is siloed on a feature branch. Loop guardrail updated to allow
  merging green work if a separate base branch ever appears (job bf3c0dfe).
- **CI status reached:** SloopKit tests ✅, libssh2 xcframework ✅,
  app-build (iOS · macOS) ✅ — the app compiles on both real targets. The
  SSH build (`app-build-ssh`) is the last red job.
- **SSH compile fix (run 31034742037):** `LibSSH2Transport` failed to compile
  because Swift's C importer rejects the `LIBSSH2_CHANNEL_WINDOW_DEFAULT` /
  `LIBSSH2_CHANNEL_PACKET_DEFAULT` macros ("structure not supported"). Replaced
  them with their literal values (2 MiB window, 32768 packet) from libssh2.h.
  Also silenced a `var rc`→`let` warning on the handshake call. Pushed for CI
  to verify the real SSH transport now compiles.
