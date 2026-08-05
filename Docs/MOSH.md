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
   Synchronization Protocol. Datagrams are AES-128-OCB encrypted with the key;
   the protocol resynchronizes screen state after any gap, so roaming and sleep
   just work.

## The client is C++

The Mosh client (`mosh-client`, the `network::` + `terminal::` layers) is C++
and depends on Protocol Buffers. To use it on Apple platforms:

- Cross-compile it (and protobuf) for `ios-arm64`, the simulator, `macos-arm64`,
  and `tvos-arm64`; package as `Vendor/mosh.xcframework`.
- Or port just the SSP transport (`network/network.cc`, `crypto/`, the OCB and
  transport-fragment code) to a focused static lib — smaller surface, no
  terminal layer needed since SwiftTerm already renders.

Then implement `MoshTransport: Transport`:

- `start()` — assume the caller already has a `MoshBootstrap` (from the SSH
  bootstrap step). Open UDP, hand the key to the SSP layer, begin the
  send/receive loop.
- `send` / `onData` — feed keystrokes into SSP; deliver diffs as bytes to the
  terminal.
- Reconnect transparently when the network path changes (`NWPathMonitor`) or the
  app returns from suspension.

## Licensing note

Mosh is GPLv3. Bundling it has App Store implications — see
`Docs/LICENSING.md` and settle that before shipping Mosh.
