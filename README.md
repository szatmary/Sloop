# Sloop ⚓

A free, native terminal for Apple platforms — iPhone, iPad, Mac, and tvOS.
SSH and Mosh, a real terminal emulator, and proper keyboard support. Think
Blink Shell, rebuilt native and given away.

> **Status: early scaffold.** The core library and app skeleton are in place and
> a local echo terminal runs today. SSH (libssh2) and Mosh are stubbed with a
> clear integration path. See [`Docs/ROADMAP.md`](Docs/ROADMAP.md).

## Architecture

Sloop is split so the logic is testable without a Mac and the UI stays thin:

| Layer | Where | Depends on | Builds on |
| --- | --- | --- | --- |
| **SloopKit** — transports, session & host models, SSH/Mosh plumbing | `Sources/SloopKit` | Foundation only | any platform, incl. Linux CI |
| **App** — SwiftUI multiplatform UI wrapping SwiftTerm | `App/Sloop` | SwiftTerm + SloopKit | Xcode (iOS/tvOS/macOS) |

The seam between them is the [`Transport`](Sources/SloopKit/Terminal/Transport.swift)
protocol: bytes in via `onData`, keystrokes out via `send`. The UI never needs to
know whether it's talking to a local echo loop, an SSH channel, or a Mosh
session.

- **Terminal renderer:** [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  (MIT), xterm-compatible, native.
- **SSH:** libssh2, to be vendored as an `.xcframework` — see [`Docs/SSH.md`](Docs/SSH.md).
- **Mosh:** cross-compiled client — see [`Docs/MOSH.md`](Docs/MOSH.md).

## Getting started (macOS)

```sh
brew install xcodegen
xcodegen generate
open Sloop.xcodeproj
```

Pick the `Sloop_iOS`, `Sloop_tvOS`, or `Sloop_macOS` scheme and run. The
**Local terminal** row works immediately; saved hosts will show the SSH
"not implemented yet" fallback until libssh2 is wired up.

## Testing the core

SloopKit is pure Foundation, so its tests run anywhere Swift does:

```sh
swift test
```

## Docs

- [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) — how the pieces fit
- [`Docs/ROADMAP.md`](Docs/ROADMAP.md) — milestones toward SSH + Mosh
- [`Docs/SSH.md`](Docs/SSH.md) — building & wiring libssh2
- [`Docs/MOSH.md`](Docs/MOSH.md) — the Mosh bootstrap and client
- [`Docs/LICENSING.md`](Docs/LICENSING.md) — the GPL / App Store question (decide before shipping)
