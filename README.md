# Sloop ⚓

A free, native terminal for Apple platforms — iPhone, iPad, Mac, and tvOS.
SSH and Mosh, a real terminal emulator, and proper keyboard support — a
first-class mobile shell, native and given away.

> **Status: working, unreleased.** SSH (libssh2 + OpenSSL 3) and Mosh both
> connect on device, with a shared key library synced through iCloud Keychain
> and host-key pinning. Cloudflare Access tunnels are implemented and unit
> tested but not yet exercised against a live Access application. Not signed
> for distribution. See [`Docs/ROADMAP.md`](Docs/ROADMAP.md).

## Architecture

Sloop is split so the logic is testable without a Mac and the UI stays thin:

| Layer | Where | Depends on | Builds on |
| --- | --- | --- | --- |
| **SloopKit** — transports, session & host models, SSH/Mosh plumbing | `Sources/SloopKit` | Foundation only | any platform, incl. Linux CI |
| **App** — SwiftUI multiplatform UI wrapping SwiftTerm | `App/Sloop` | SwiftTerm + SloopKit | Xcode (iOS/tvOS/macOS) |

The seam between them is the [`Transport`](Sources/SloopKit/Terminal/Transport.swift)
protocol: bytes in via `onData`, keystrokes out via `send`. The UI never needs to
know whether it's talking to an SSH channel or a Mosh session.

- **Terminal renderer:** [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
  (MIT), xterm-compatible, native.
- **SSH:** libssh2 over OpenSSL 3, vendored as an `.xcframework` — see [`Docs/SSH.md`](Docs/SSH.md).
- **Mosh:** cross-compiled client — see [`Docs/MOSH.md`](Docs/MOSH.md).

## Getting started (macOS)

```sh
brew install xcodegen
xcodegen generate
open Sloop.xcodeproj
```

Pick the `Sloop_iOS` or `Sloop_macOS` scheme and run, then add a host and
connect. The plain `project.yml` builds without SSH, and each host shows build
instructions instead of connecting: link the libssh2 xcframework
(`Docs/SSH.md`) for real connections, and generate from `project.mosh.yml` to
include Mosh (`Docs/MOSH.md`). tvOS is deferred — see
`Docs/ROADMAP.md`.

On a Mac, `Scripts/sloop import-key ~/.ssh/id_ed25519` puts a key into the
shared library, where every device running Sloop will find it.

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
- [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) — dependencies and their licenses

## License

Sloop is [GPL-3.0](LICENSE) — it bundles [Mosh](https://mosh.org), whose
copyleft governs the combined work.

Most of Sloop's own code was written with LLM assistance under human direction.
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) covers that, the
dependencies, and the reservation on the Sloop name and icon.
