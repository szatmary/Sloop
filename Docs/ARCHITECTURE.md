# Architecture

## Layers

```
┌───────────────────────────┐  ┌──────────────────────────────┐
│ App/Sloop  (SwiftUI)      │  │ App/SloopFiles (extension)   │
│  SloopApp → HostListView  │  │  FileProviderExtension       │
│  SwiftTermView ⇄ SwiftTerm│  │  FileProviderEnumerator      │
│  HostKeyPrompter (UI)     │  │  SFTPDomainService           │
└─────────────┬─────────────┘  └──────────────┬───────────────┘
              │        both embed             │
┌─────────────┴───────────────────────────────┴───────────────┐
│ App/SloopSSH  (framework — needs libssh2/tsnet)             │
│  LibSSH2Connection  LibSSH2Transport  LibSSH2SFTPClient     │
│  HostDialer  TransportFactory  SFTPClientFactory            │
│  TailscaleNode  TailscaleDialer                             │
│  Keychain stores (credentials, keys, Access tokens)         │
└──────────────────────┬──────────────────────────────────────┘
                       │  Transport / Dialer / SFTPClient protocols
┌──────────────────────┴──────────────────────────────────────┐
│ SloopKit  (Foundation only, testable on Linux)              │
│  Transport  TerminalSession  OpenSessions  Dialer           │
│  MoshBootstrap  MoshOrSSHTransport  SFTPClient  SFTPEntry   │
│  SFTPItemIndex  RemotePath  Host  HostStore  SloopStorage   │
└─────────────────────────────────────────────────────────────┘
```

**Why three layers and not two.** SloopKit stays Foundation-only so `swift test`
runs on Linux CI — libssh2 in it would end that. But `App/Sloop` is the *app
target's* source list, which an app extension cannot link. The File Provider
extension needs the transports, dialers, keychain stores and SFTP client, so
they live in a framework both targets embed. Anything with a view in it stays
in the app.

## The Transport seam

Everything the terminal talks to implements one protocol:

```swift
protocol Transport: AnyObject {
    var onData: ((ArraySlice<UInt8>) -> Void)? { get set }   // remote → terminal
    var onOpen: (() -> Void)? { get set }                    // established → "connected"
    var onClose: ((Error?) -> Void)? { get set }
    func start()
    func send(_ bytes: ArraySlice<UInt8>)                    // terminal → remote
    func resize(cols: Int, rows: Int)
    func close()
}
```

Implementations:

- **`LibSSH2Transport`** — a libssh2 shell channel over OpenSSL 3. Lives in
  `App/SloopSSH/` (not SloopKit), and takes a `Dialer` — see "Dialers" below.
- **`MoshTransport`** — Mosh SSP over UDP, via the `MoshBridge` Objective-C++
  shim over mosh's C++ client core. `MoshBootstrap` parses the `MOSH CONNECT`
  handshake that starts it. Built in the Mosh variant only
  (`project.mosh.yml`); which one a host gets — and whether it dials for itself
  or is handed a tunnel socket — is
  [`MoshTransportFactory`](../App/Sloop/SSH/MoshTransportFactory.swift)'s
  answer, the sibling of `TransportFactory` for the SSP leg.
- **`MoshOrSSHTransport`** — composes the two: probes for `mosh-server` over an
  SSH exec channel and activates whichever transport the host can support,
  buffering input and geometry until that's decided. Where Mosh isn't built in,
  the probe always ends in SSH.

An `EchoTransport` came first — local, no network — and was removed once both
real transports worked. It only ever demonstrated this seam.

`SwiftTermView.Coordinator` is the only place the two worlds meet: it implements
`TerminalViewDelegate` (SwiftTerm → us) and pumps `onData` back into the view.

### Asking a session a question

Some features want to ask the host something over a connection the session
already holds — the shell-history import
([`ShellHistoryImporter`](../Sources/SloopKit/Suggest/ShellHistoryImporter.swift))
is the one that exists. That's
[`SessionCommandRunner`](../Sources/SloopKit/Suggest/SessionCommandRunner.swift),
and the rule is **register before `start()`**:

```swift
public protocol SessionCommandRunner {
    func requestOnSession(_ command: String, completion: @escaping (String?) -> Void)
}
```

Registering, not invoking, because *when* a session can afford to ask differs
and the caller has no way to know which kind of session it got:

- **SSH** waits until the shell is up, then runs it on a second channel. The
  connection the user asked for does not queue behind a convenience.
- **Mosh** folds it into the bootstrap exec via
  [`MarkedCommandBatch`](../Sources/SloopKit/Terminal/MarkedCommandBatch.swift),
  which runs N commands in one shell invocation and splits their outputs back
  apart. That exec is the only SSH connection a Mosh session will ever have, and
  it closes before the terminal opens — so a question not asked there can never
  be asked at all.

`MoshOrSSHTransport` queues requests until the probe answers, then either lets
the bootstrap's output satisfy them or hands them to the SSH transport it fell
back to. Every completion fires exactly once, `nil` when there was no connection
to ask on — including a request that arrived after a Mosh session went live, and
one outstanding when the tab closed.

Letting each caller decide the timing is what forked this in two: `runOnSession`
for SSH and a separate history-shaped callback for Mosh, which
`TerminalController` reached by casting to `MoshOrSSHTransport` — the same
cast-to-a-concrete-transport mistake this protocol's doc comment warns about,
one layer up. A composing transport can forward a protocol; a cast has no way
to.

## Dialers: how the byte stream is established

`Transport` says nothing about how bytes reach the SSH server; that's one
layer down, the `Dialer` seam
([`Sources/SloopKit/Net/Dialer.swift`](../Sources/SloopKit/Net/Dialer.swift)):

```swift
public protocol Dialer: AnyObject {
    func dial() throws -> Int32
}
```

`dial()` is called once, on a background thread, and may block; it returns a
connected, bidirectional socket fd that the caller owns and closes.
`LibSSH2Transport` (the interactive shell) and `LibSSH2CommandRunner` (the
Mosh SSH-exec bootstrap) both take a `Dialer` and run libssh2's handshake,
host-key check, and read/write pump over whatever fd it hands back — the SSH
side never knows which dialer produced it.

- **`TCPDialer`** — `getaddrinfo` + `connect`, the direct path.
- **`CloudflareAccessDialer`**
  ([`Sources/SloopKit/Cloudflare/CloudflareAccessDialer.swift`](../Sources/SloopKit/Cloudflare/CloudflareAccessDialer.swift))
  — what `cloudflared access ssh` does, natively: a `URLSessionWebSocketTask`
  WebSocket to `wss://<hostname>`, the Access JWT in the `cf-access-token`
  request header, binary frames carrying the raw SSH byte stream. A
  [`SocketPairRelay`](../Sources/SloopKit/Net/SocketPairRelay.swift) bridges
  that callback-shaped stream to one end of a `socketpair()` and hands the
  other end out as the fd libssh2 runs over. It pings every 30 s and runs with
  URLSession's timeouts pushed out of the way, because an idle tunnel must
  outlive silence rather than be ended by it — the same lesson as 64ca4d7 on
  the Mosh side. Note that a dropped WebSocket
  reaches libssh2 as a *clean EOF* — the relay calls `finishInbound()`, so the
  fd half-closes and `read()` returns 0. Any bug about libssh2 mishandling a
  negative return (a TCP reset, a vanished network) is therefore a
  direct-TCP-path problem; don't go looking for it in the relay.
- **`TailscaleDialer`**
  ([`App/SloopSSH/TailscaleDialer.swift`](../App/SloopSSH/TailscaleDialer.swift))
  — Sloop's own tailnet node. `tailscale_dial` hands back an ordinary socket
  fd, so libssh2 cannot tell a tailnet connection from a direct one and the
  whole integration fits behind `Dialer`. The node comes up inside the first
  dial rather than at launch: a user with no tailnet hosts never pays for a
  WireGuard node, and one who has them expects the first connect to be where
  "authorize this device" appears. Lives in the app rather than SloopKit
  because it needs `libtailscale`, which only the `.tailscale` build variant
  links; other variants compile a stub that says the method is unavailable.

Cloudflare Access hosts are SSH-only: Mosh needs UDP, which a
TCP-over-WebSocket tunnel can't carry, so `HostEditView` disables "Use Mosh"
for them.

Tailscale hosts carry Mosh, but not through the `Dialer` — **that seam carries
the SSH leg only.** Mosh's SSP leg is a socket `MoshTransport` gets for itself,
so reaching a tailnet host meant giving it one that speaks to the tailnet:
`TailscaleNode.dialUDP` opens the SSP socket through the same tsnet node that
carries SSH, and `MoshTransport(host:bootstrap:dialTunnel:)` hands the fd to
mosh instead of an address to dial.

Two things had to change underneath for that fd to be usable:

- **libtailscale** bridges every dialed connection to C through a `SOCK_STREAM`
  socketpair, which destroys message boundaries — four packets sent back to
  back arrive as one 2545-byte read, and mosh puts one SSP frame per packet, so
  the first coalesced pair fails to decrypt. `Scripts/libtailscale-sloop-udp.go`
  adds a `udp` dial that bridges through `SOCK_DGRAM`, where one write is one
  datagram. It sits beside upstream's code rather than patching it, the same
  way the status export does.
- **mosh** opens its own socket and addresses every packet with `sendto`, which
  a connected socket refuses. `Scripts/patches/mosh-tunnel-fd.patch` adds a
  client `Connection` that adopts a connected fd, sends with `send`, and skips
  port hopping — hopping the source port means nothing when the port the server
  sees belongs to the tunnel.

Cloudflare Access cannot be fixed the same way: TCP inside a WebSocket has
nowhere to put a datagram at all, so `HostEditView` still disables "Use Mosh"
there. `ConnectionMethod.carriesMosh` is the single statement of which methods
can, and it lives on the model because the two places that need it drifted
apart — the host editor offered Mosh over Tailscale while the connect path
silently ran SSH, so the toggle stayed on and did nothing.

`HostEditView` disables the "Use Mosh" toggle whenever
`connectionMethod.carriesMosh` is false, and resets `useMosh` when the method
changes — so does the host row's "mosh" badge and the connect path, all reading
that one property rather than restating the rule.

### Which dialer: one switch, two audiences

[`HostDialer.resolve`](../App/SloopSSH/HostDialer.swift) is the only place that
maps a `ConnectionMethod` to a `Dialer`. `TransportFactory` (the shell),
`CommandRunnerFactory` (the Mosh probe) and `SFTPClientFactory` (the File
Provider) all ask it.

That matters more than it sounds. Every time a caller has decided this for
itself, the copies have drifted: the Mosh probe once hard-coded `.direct` and a
`TCPDialer`, so a tailnet host's probe refused to run and every Mosh session
over the tailnet quietly became an SSH one; the File Provider later grew its own
switch, which had already begun to diverge on the tailnet role and the hostname
check.

The callers genuinely disagree about exactly one thing, so it is a parameter
(`TailnetFallback`) rather than a second switch: in a build that links no
`libtailscale`, the terminal may fall back to an ordinary dial when the
Tailscale app's system VPN happens to be up — the user is present and watching
— while the File Provider refuses, because the system wakes it in the background
and a route that exists now is not something a saved domain can rely on.

Why a host *can't* be dialed is a type too, `DialerUnavailable`, because the
same reason must reach two audiences: someone at a terminal inside Sloop
("go back to the host list") and someone looking at a folder in Files.app that
won't open ("open Sloop"). It carries `terminalText` and `errorDescription` side
by side, so a new case can't be added without answering for both, and conforms
to `UserActionRequiredError` so `FileProviderError` turns it into the
`notAuthenticated` that makes Files.app show a next step instead of spinning.

Note it is *not* gated on `canImport(CSSH)`, though every caller feeds the
result to libssh2: nothing about choosing a dialer needs libssh2, and leaving
the decision buildable everywhere is what lets it be tested in the plain build
CI actually runs.

### Getting the Access token

A `WKWebView` sheet
([`AccessLoginView`](../App/Sloop/Cloudflare/AccessLoginView.swift)) loads
`https://<hostname>`, lets Access bounce through the identity provider, and
after every navigation reads the `CF_Authorization` cookie for that hostname
from the web view's cookie store — that cookie's value *is* the JWT, no
separate token exchange. `HostListModel.needsAccessLogin(_:)` checks for a
valid stored token before connecting and routes to this sheet when one's
missing or expired; `TransportFactory` re-resolves the token at connect time
so a fresh login is picked up immediately.

Tokens live behind the `AccessTokenStore` protocol
([`Sources/SloopKit/Cloudflare/AccessTokenStore.swift`](../Sources/SloopKit/Cloudflare/AccessTokenStore.swift)),
keyed by lowercased hostname — a Keychain-backed implementation in the app
(one generic-password item per hostname), `InMemoryAccessTokenStore` in tests.
The key is the hostname rather than the host id because the token *is* one
Access application's session: several saved hosts may sit behind one Access
app and share it. So signing out is hostname-wide on purpose, while deleting a
host only drops the token when no remaining host still reaches that hostname
through Access (`accessTokenIsStillNeeded(for:by:)`).
`AccessToken` parses only the JWT payload's `exp` client-side (no signature
check, and no audience check: the app is the bearer, not the verifier) to
decide if a stored token is still worth trying before dialing. A WebSocket upgrade that
Cloudflare's edge rejects for lack of a session produces
`SSHError.accessLoginRequired`; one it rejects because the policy denies the
authenticated identity produces `SSHError.accessDenied`.

### Two things worth knowing

- **The login sheet keeps nothing.** `AccessLoginView` runs on a
  *non-persistent* `WKWebsiteDataStore`, so no `CF_Authorization` cookie
  survives from one presentation to the next and every sheet is a real round
  trip through Access and the IdP. That is what makes clearing the stored
  token — "Sign Out of Cloudflare Access", deleting a host, or
  `TokenClearingDialer` dropping a token the edge rejected — actually mean
  something. With the default persistent store it did not: the sheet's first
  `didFinish` re-captured the same cookie, committed it, and closed itself
  before the user could act, so a rejected token reinstated itself until its
  own `exp` passed. The cost is that a renewal asks the IdP again instead of
  completing from a still-logged-in browser session.
- **A parent-domain cookie is accepted.** `accessCookieDomainMatches`
  ([`Sources/SloopKit/Cloudflare/AccessCookie.swift`](../Sources/SloopKit/Cloudflare/AccessCookie.swift))
  treats a `CF_Authorization` cookie scoped to `.example.com` as valid for
  `ssh.example.com`. That doesn't widen the browser's own trust boundary — the
  cookie was already scoped that broadly by whatever server set it — and
  Cloudflare's edge still rejects a token whose `aud` claim doesn't match the
  application being dialed. Worth knowing, not a bug.

## Files.app: the SFTP seam

`SFTPClient` ([`Sources/SloopKit/SFTP/SFTPClient.swift`](../Sources/SloopKit/SFTP/SFTPClient.swift))
is the `Transport` trick one subsystem over — a protocol with the libssh2
implementation behind it, so the whole File Provider extension is written
against it and tested against `InMemorySFTPClient` on Linux CI. Only
`LibSSH2SFTPClient` needs a server.

A published host becomes one `NSFileProviderDomain`, its identifier the host's
UUID. Three things about it are worth knowing before changing anything:

- **Identifiers are not paths.** `NSFileProviderItemIdentifier` must survive a
  rename; an SFTP path does not. `SFTPItemIndex` mints a stable UUID per path
  and rewrites the path underneath it, carrying a whole subtree when a directory
  moves. Using the path as the identifier is the obvious shortcut and corrupts
  the replica on the first rename — as a wrong answer at runtime, not a build
  error.
- **There is no change feed.** SFTP cannot push, so `enumerateChanges` re-lists
  and diffs against the attributes the index recorded last time. Consequence,
  by design: a file changed by someone else over SSH appears when Files.app next
  asks, not the moment it happens. Sloop's own changes are signalled immediately.
- **The extension cannot ask a question.** It runs while the app does not and has
  no UI. So it uses `StrictHostKeyVerifier` — never trust-on-first-use — and
  turns an unknown host key, an expired Access token, a missing credential, or an
  unauthorized tailnet device into `NSFileProviderError.notAuthenticated` with
  the sentence that fixes it. That error code is what makes Files.app offer a
  way forward instead of spinning; `signalErrorResolved` clears it once the app
  has done the thing. Anything conforming to `UserActionRequiredError` lands
  there, rather than a hand-kept list of error types — the list had already
  missed the tailnet case.
- **Only two error domains exist here.** `NSFileProviderErrorDomain` and
  `NSCocoaErrorDomain`. The system treats every other domain as transient and
  retries it forever, so `FileProviderError` maps into those two and never into
  `NSPOSIXErrorDomain` — which it did at first, on the mistaken belief that
  Files.app read errno directly. The symptom of getting this wrong is nothing
  at all: no error, no log, just an operation that never settles.

Shared state lives in the App Group (`SloopStorage`): the host list, known
hosts, each domain's item index, and tsnet state. Per-host credentials and
Access tokens live in a keychain access group shared with the extension —
deliberately *not* the iCloud-synced key-library group, since those items are
device-only on purpose.

The extension runs **its own tsnet node**, a second device on the tailnet. Two
processes cannot share one node key: the control plane would see a single device
flapping between endpoints. Whether a ~23 MB Go runtime fits inside a File
Provider extension's memory cap is still unmeasured — see `Docs/ROADMAP.md`.

## Why the split

- **Testable core.** SloopKit has no UIKit/AppKit, so `swift test` runs on Linux
  CI and catches regressions in parsing, persistence, and byte handling without
  a simulator.
- **Thin UI.** The SwiftUI layer is mostly wiring; platform differences are a
  handful of `#if os(...)` blocks (keyboard bar on iOS, representable type on
  macOS).
- **One codebase, four platforms.** XcodeGen expands the single app target to
  iOS/tvOS/macOS. Mac gets a native build; it also runs the iOS build directly
  on Apple Silicon.

## Threading

Transports may deliver `onData` off the main thread (SSH/Mosh read loops will).
The coordinator hops to `DispatchQueue.main` before every `feed(...)`. Keep that
invariant when adding transports.
