# Tunnel integrations: Cloudflare Access + Tailscale

_Approved 2026-08-12. Feature: reach SSH hosts behind Cloudflare Tunnel or on a
Tailscale tailnet from inside the app, on iOS and macOS alike._

## Revision 2026-08-17 — the SSH library moves to swift-nio-ssh

The Cloudflare **carrier** is re-planned; everything else in this spec stands.

`SocketPairRelay` and the WebSocket half of `CloudflareAccessDialer` exist for
one reason: libssh2 demands a blocking file descriptor, while a WebSocket is
callback-shaped. NIO removes that mismatch — the carrier becomes a WebSocket
`ChannelHandler` sitting in the same pipeline as `NIOSSHHandler`, with NIO
supplying backpressure. No socketpair, no pump thread, no semaphores, no fd
lifetime to manage.

That matters because every defect found while building the bridge — a
self-joining teardown deadlock, a three-way deadlock between URLSession's
serial delegate queue and the blocking inbound write, a use-after-close on a
recycled descriptor, and hand-rolled send backpressure — is an artifact of the
bridge itself, not of the Access protocol. They do not exist in a NIO pipeline.

**Unchanged by the pivot:**

- The `Dialer` seam. NIO adopts an already-connected socket via
  `ClientBootstrap.withConnectedSocket(descriptor:)`, which is exactly what
  `dial()` returns, so `TCPDialer` and a future `TailscaleDialer` plug in as
  designed.
- `SSHHost.connectionMethod`, `AccessToken` / `AccessTokenStore`, the Keychain
  store, the browser-SSO sheet, and the host UI — all transport-agnostic.
- The **entire Tailscale plan**: libtailscale's dial returns a real socket fd.
- The verified Access wire protocol: `Cf-Access-Token` header, raw bytes in
  binary WebSocket frames, no extra framing (checked against cloudflared
  source, and re-confirmed independently in review).

**Superseded:** the `SocketPairRelay` bridge and the URLSession-based carrier
in `CloudflareAccessDialer`. Both remain on the tunnels branch as a protocol
reference for the NIO rewrite, unwired and **not finished** — one Important
review finding is still open against the relay's teardown path. Do not treat
that code as shippable.

## Problem

Sloop can only SSH to hosts that are directly reachable: `LibSSH2Transport`
resolves the hostname with `getaddrinfo` and hands libssh2 a plain connected
TCP socket. Machines behind Cloudflare Tunnel (the maintainer's own setup) or
on a Tailscale tailnet (widely popular) are invisible to it. Desktop users
solve this with `ProxyCommand cloudflared access ssh …` or the Tailscale VPN,
but iOS cannot spawn helper processes and Sloop should not require a separate
VPN app — so both integrations must run **in-process**.

## Decisions (from brainstorming)

- **Both integrations**, sequenced: enabling refactor → Cloudflare (maintainer's
  use case) → Tailscale.
- **Cloudflare auth is browser SSO** (Access app gated by an identity provider).
  Service tokens are out of v1; the token store leaves room for them later.
- **SSH-only through tunnels.** Mosh needs UDP: it cannot traverse Cloudflare
  Access (TCP-over-WebSocket only) and is unverified over embedded Tailscale.
  Mosh remains available for directly-reachable hosts; the UI says why it is
  disabled for tunneled ones.
- **Tailscale ships with full browser login in v1** (the flow the audience
  expects), not auth-key paste.
- **In-process dialers** (approach A) over embedding the vendors' Go daemons
  via gomobile (rejected: two Go runtimes, `cloudflared` is not a library) and
  over shelling out to installed CLIs (rejected: macOS-only).
- **Never fall back silently.** A tunnel that cannot connect surfaces a
  specific error state; the app never quietly retries over direct TCP.

## Architecture: the `Dialer` seam

The same trick as `Transport`, one level down. Everything both tunnels need is
"a different way to produce the byte stream libssh2 runs over":

```swift
public protocol Dialer {
    /// Returns a connected, bidirectional socket fd carrying a byte stream
    /// to the SSH server. Caller owns and closes the fd.
    func dial() async throws -> Int32
}
```

- `LibSSH2Transport`'s hardcoded resolve-and-connect moves into a `TCPDialer`;
  the transport receives a `Dialer` and its handshake, host-key verification,
  and `select()` pump are untouched — every dialer yields a real fd.
- `SSHHost` gains `connectionMethod: ConnectionMethod` — `.direct`,
  `.cloudflareAccess`, `.tailscale` — Codable with the model's usual defensive
  decoding, defaulting to `.direct` for existing saved hosts.
- `TransportFactory` maps the method to a dialer.
- **`SocketPairRelay`** (SloopKit, unit-tested): bridges an async byte stream
  to one end of a `socketpair()` and hands libssh2 the other end, so
  stream-shaped sources (the Cloudflare WebSocket) look like sockets too.

M1 lands this as a pure refactor: no behavior change, tests stay green.

## Cloudflare Access (M2)

What `cloudflared access ssh` does, natively:

- **`AccessDialer`** — opens a WebSocket to `https://<hostname>` via
  `URLSessionWebSocketTask` with the Access JWT in the `cf-access-token`
  header; binary frames carry the raw SSH byte stream, bridged through
  `SocketPairRelay`. First implementation task verifies exact header and
  framing details against the cloudflared source (`carrier` package).
- **`AccessTokenStore`** (SloopKit, unit-tested) — one JWT per Access app,
  keyed by hostname; parses the payload client-side for `exp`/`aud` to detect
  staleness (no signature verification — the app is the bearer, not the
  verifier). Persisted via the existing Keychain pattern. Extensible to a
  service-token credential kind later.
- **Browser SSO** — a `WKWebView` sheet loads `https://<hostname>`; Access
  bounces through the IdP; on return the app reads the `CF_Authorization`
  cookie for that hostname from the web view's cookie store. That cookie *is*
  the JWT. No localhost callback server and no edge token-transfer dance —
  those exist because a CLI has no browser; we have one in-process.
- Connecting with a missing/expired token throws
  `SSHError.accessLoginRequired`; the UI presents the login sheet and the user
  retries. Access denying the identity (403 after login) is
  `SSHError.accessDenied` — distinct, actionable, not retried.

## Tailscale (M3)

- **Vendored TailscaleKit / libtailscale** — Tailscale's official embeddable
  userspace node with Swift 6 bindings; builds separate macOS/iOS/simulator
  frameworks suitable for App Store submission. BSD-3-Clause.
  `Scripts/build-libtailscale.sh` (requires a Go toolchain, like the mosh
  script) produces xcframeworks into `Vendor/`, following the libssh2/mosh
  vendoring pattern.
- **`TailnetManager`** (app layer) — owns the singleton node: lazy-starts on
  first use, keeps node state in Application Support, exposes status. Login:
  the node reports "needs login" plus a URL; the app opens it in a browser
  sheet; the user approves; the node polls its way to Running. No callback
  capture.
- **`TailscaleDialer`** — dials `host:22` over the tailnet (MagicDNS name or
  100.x address). libtailscale's C dial returns a real socket fd (no relay);
  if implementation prefers TailscaleKit's async API, it goes through
  `SocketPairRelay` instead. Implementation-time call.
- **Risk gate, checked first:** tailscale/tailscale#15410 (closed) was an iOS
  sandbox failure in `os.Executable()` inside TailscaleKit. Before any
  integration work, run TailscaleKit's hello example on a real iOS device; a
  regression kills the milestone cheaply.
- Errors: `SSHError.tailnetLoginRequired`, `SSHError.tailnetUnavailable`.

## Host model & UI

- `HostEditView` gets a connection-method picker. Cloudflare: the hostname
  field is the Access app hostname; the port field is hidden (wss/443 outside,
  sshd inside the tunnel). Tailscale: hostname is the MagicDNS name or tailnet
  IP; port defaults to 22.
- Mosh toggle disabled for tunneled hosts with a one-line explanation.
- Settings gains a Tailscale section (status / login / logout) in M3.
- SSH-config import mapping `ProxyCommand cloudflared access ssh` →
  `.cloudflareAccess` is a noted future parser enhancement, not v1.

## Packaging, builds, licensing

- Cloudflare support is pure Swift: always built, no variant.
- Tailscale follows the layered-build pattern: `project.tailscale.yml` variant,
  `#if canImport(TailscaleKit)` fallback messaging in `TransportFactory`
  (exactly how CSSH degrades today), and a CI job mirroring `app-build-mosh`.
- THIRD-PARTY-NOTICES gains libtailscale (BSD-3). The Access client is
  original code implementing a wire protocol; cloudflared (Apache-2.0) is
  reference only, and Apache-2.0 is GPL-3.0-compatible even if code is later
  borrowed.
- Binary size: the embedded Go runtime adds roughly 20–40 MB to
  Tailscale-enabled builds; the variant keeps base/SSH/Mosh builds lean.

## Testing

- SloopKit unit tests: `ConnectionMethod` Codable round-trips (including
  unknown-value defensive decoding), JWT payload parse/expiry/audience,
  `SocketPairRelay` under partial reads, backpressure, and half-close, and
  `AccessDialer` against an in-process WebSocket echo server on CI.
- Tailscale cannot run in unit tests: `Docs/HANDOFF.md` device-test checklist
  gains a tailnet section (login, dial, reconnect after backgrounding).
- Milestone gates: M1 all existing tests green with zero behavior change;
  M2 verified against the maintainer's real Cloudflare Tunnel; M3 verified on
  a real tailnet on device.

## References

- TailscaleKit: <https://github.com/tailscale/libtailscale/tree/main/swift>
- cloudflared token handling:
  <https://github.com/cloudflare/cloudflared/blob/master/token/token.go>
- iOS sandbox issue (closed):
  <https://github.com/tailscale/tailscale/issues/15410>
