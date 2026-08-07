# Mosh: bootstrap and client

[Mosh](https://mosh.org) is what makes a mobile terminal actually usable: the
session survives IP changes, sleep, and lossy links. It's the hardest piece of
Sloop and lands after a working SSH terminal (see `Docs/ROADMAP.md`, M3).

## How Mosh connects

1. **Bootstrap over SSH.** SSH into the host and run:
   ```sh
   mosh-server new -s -c 256 -l LANG=en_US.UTF-8
   ```
   It prints one line and daemonizes:
   ```
   MOSH CONNECT 60001 4NeCCgvZFe2RnPgrcU1PQw
   ```
   `MoshBootstrap(serverBanner:)` parses the UDP port and the base64 key.
2. **Speak SSP.** Close the SSH connection. Open a UDP socket to
   `host:60001`, set `MOSH_KEY` in the environment, and run the Mosh State
   Synchronization Protocol.

## Prefer Mosh, fall back to SSH

Upstream Mosh errors out if `mosh-server` isn't on the remote. Sloop doesn't:
because the bootstrap runs over an SSH connection we already hold, a missing (or
broken) server just falls back to a normal SSH shell.

The decision lives in SloopKit and is unit-tested with a mock command runner (no
network, no Mac):

- `MoshServer.bootstrapCommand` — the `mosh-server new …` command.
- `MoshServer.interpret(_:)` — classify the command output into
  `MoshStartup.connect(MoshBootstrap)` (got a handshake → go to SSP) or
  `.unavailable(reason:)` (not installed / bad locale / didn't start → SSH).
- `MoshBootstrapper(runner:)` — runs the command over a `CommandRunner` (an SSH
  exec channel) and reports the `MoshStartup`.

So `host.useMosh` means *prefer* Mosh: hosts that have it get roaming and
predictive echo; hosts that don't still connect over plain SSH.

This is wired into the live connect path via `MoshOrSSHTransport` (SloopKit): a
`Transport` that, when Mosh is requested, probes `mosh-server`, then activates
either a Mosh transport or a plain SSH shell and forwards the whole transport
surface to whichever is live. It prints a one-line notice so you can see the
mode (`[sloop] mosh: … — using SSH`). `HostListModel.connect` builds one when
`host.useMosh` is set. The branching is unit-tested with mock transports + a mock
command runner.

**Status:** the `MoshTransport` UDP/SSP session (below) is now built in the Mosh
variant — `HostListModel` supplies a real Mosh-transport factory there, so a
Mosh-capable host gets a genuine Mosh session instead of the SSH fallback. In the
plain SSH build (no `SLOOP_MOSH`) the factory stays nil and `MoshOrSSHTransport`
still falls back to SSH after the probe, as before. The probe/branch/notice path
is real and unit-tested either way. (Fallback cost: probing opens a short extra
SSH exec connection; on a Mosh-capable host with no Mosh transport wired, the
started `mosh-server` is left to time out while we use SSH.)

### SSP details

Datagrams are AES-128-OCB encrypted with the key; the protocol resynchronizes
screen state after any gap, so roaming and sleep just work.

## Cross-compiling mosh for Apple — findings (step 3)

A crypto-only probe (cross-compile just mosh's OCB into an xcframework, to
de-risk the toolchain before the full build) taught us the shape of the real
work, then was retired:

- **mosh clones and builds cleanly**; the source tree is straightforward.
- **No external crypto library is required on Apple.** mosh 1.4 ships several
  OCB backends as separate files — `ocb_openssl.cc`, `ocb_nettle.cc`, and the
  self-contained `ocb_internal.cc` — and its sources include an Apple/CommonCrypto
  path. So iOS/macOS can use CommonCrypto (in the SDK) with nothing to vendor.
- **Do not hand-compile mosh files with a stubbed `config.h`.** `ocb_internal.cc`
  is Krovetz's reference OCB; its portable declarations are gated behind config
  macros (BPI, feature detection) that mosh's `./configure` sets. Compiling it
  directly without them fails (`undeclared identifier 'oa'`). The correct path is
  to let mosh's **autotools** configure the build.
- **Protobuf is the real dependency hurdle**, not crypto: Homebrew's modern
  abseil-based protobuf (v35, C++17) fails mosh 1.4's configure probe. The full
  build needs a mosh-compatible protobuf (e.g. `protobuf@21`, pre-abseil) or a
  vendored one.

### Revised plan

1. **`mosh.xcframework` via autotools.** ✅ Done — `Scripts/build-mosh.sh` cross-
   compiles mosh's full client library set for the Apple arm64 slices using an
   iOS CMake/autotools toolchain, mosh's **internal OCB + Apple CommonCrypto**
   AES backend (no OpenSSL to vendor), and a mosh-compatible protobuf (host
   `protoc` + target runtime, merged into `libmosh.a`). Ships headers flat.
2. **C shim** ✅ Written — `App/Sloop/SSH/MoshBridge.{h,mm}`, an Objective-C++
   bridge owning a `Network::Transport<UserStream, Complete>` on a dedicated
   thread. It mirrors upstream `stmclient`'s main loop (drain queued user events
   → `tick()` → `select()` on `network.fds()` + a self-pipe → `recv()` →
   render) and reuses mosh's own `Display::new_frame` to diff the server
   framebuffer to ANSI. Exposes a plain-C API. The only curses user
   (`terminaldisplayinit.cc`) is replaced with a curses-free `Display`
   constructor stub, so no ncurses is vendored.
3. **Swift `MoshTransport`** ✅ Written — `App/Sloop/SSH/MoshTransport.swift`
   drives the shim, forwards its framebuffer bytes to SwiftTerm, and is wired
   into the `makeMoshTransport` slot in `MoshOrSSHTransport`/`HostListModel`.

Bricks 2–3 build only in the **Mosh variant** (`project.mosh.yml`, which layers
`mosh.xcframework` + the bridging header + the `SLOOP_MOSH` flag onto
`project.ssh.yml`) and are exercised by the `continue-on-error` `app-build-mosh`
CI job — kept separate so the experimental cross-compile can never redden the
stable SSH build.

## The client is C++

The Mosh client (the `network::` + `statesync::` + `terminal::` layers) is C++
and depends on Protocol Buffers, which is why the bridge is Objective-C++ and
`mosh.xcframework` bundles a merged `libmosh.a` (all client libs + protobuf) for
`ios-arm64`, the iOS simulator, and `macos-arm64`. Sloop links the whole client
rather than porting a subset: reusing `Terminal::Complete` + `Display::new_frame`
means mosh itself parses the SSP stream and renders the framebuffer to ANSI, so
SwiftTerm just displays bytes and there's no re-implementation to keep in sync.

**Still open (follow-ups):** transparent reconnect when the network path changes
(`NWPathMonitor`) or the app resumes from suspension — mosh's roaming is built
for exactly this, but Sloop doesn't yet re-arm the socket across those events.

## Licensing note

Mosh is GPLv3. Bundling it has App Store implications — see
`Docs/LICENSING.md` and settle that before shipping Mosh.
