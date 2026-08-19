# SFTP in Files.app: a File Provider extension

_Approved 2026-08-18. Feature: saved hosts appear as locations in Files.app and
Finder, so any app on the device can browse, open, and save to them over SFTP._

## Problem

Sloop can put you on a remote shell and cannot move a file. Every workaround —
`cat`, base64 through the terminal, a detour through a cloud drive — exists
because there is no path between a remote filesystem and the rest of the
device.

The obvious feature is a transfer sheet inside the app: a file list, a download
button, an upload button. It is also the wrong one. A sheet inside Sloop can
only move files into Sloop's own container; the moment the user wants to attach
a remote log to an email, edit a remote config in a text editor, or save a
photo to a server, they are back where they started. The whole value is in
being reachable *from other apps*, and on Apple platforms there is exactly one
mechanism for that: a `FileProvider` extension. Secure ShellFish built its
identity on this; the roadmap has said so for months.

So: **Files.app is the entire user interface.** Browsing, upload, download,
rename, delete, open-in-place, and every app's own save panel come from Apple's
UI for free. Sloop's own UI gains one toggle and one error surface.

## Decisions (from brainstorming)

- **File Provider extension only.** No in-app file browser in v1. It would
  duplicate what Files.app already does well, and it is not the piece nothing
  else can substitute for.
- **All three connection methods**: direct, Cloudflare Access, Tailscale.
- **The extension runs its own tsnet node**, with its own identity and its own
  state directory — see "Tailscale: a second node" below. Gated on a memory
  spike that runs before anything else is built.
- **Replicated extension** (`NSFileProviderReplicatedExtension`), the modern
  API and the only one macOS supports.
- **Opt-in per host.** One domain per host, created when the user flips "Show
  in Files" — not automatic for every saved host, which would have Files.app
  dialing hosts nobody asked it to.
- **iOS validated; macOS wired but unclaimed.** The replicated API is identical
  on both, so building for macOS costs almost nothing in code. But macOS File
  Provider needs the app properly signed and installed in `/Applications`, and
  Sloop is ad-hoc signed today (M4). macOS is not claimed as working until
  signing lands.
- **Never TOFU in the extension.** An extension cannot ask a question, and a
  process that silently trusts an unknown host key is worse than one that
  refuses.

## The shape of the problem: a second process

Everything hard about this feature follows from one fact. A File Provider
extension is a **separate process**, run by the system, usually while Sloop
itself is not running. It shares no memory with the app, and by default shares
no storage either.

Four pieces of state are app-private today and must become shared:

| What | Today | Reachable by the extension? |
| --- | --- | --- |
| `sloop-hosts.json` | app Application Support (`HostStore`) | no |
| known host keys | app Application Support (`KnownHostsStore`) | no |
| per-host credentials | keychain, **default** access group | no |
| Cloudflare Access tokens | keychain, **default** access group | no |

The keychain half is easy to miss. `GenericPasswordStore.baseQuery` sets no
`kSecAttrAccessGroup`, so both stores inherit the default group — which, per
the comment in `Sloop.entitlements`, is deliberately the app's own private
group and not the shared key-library one. Only the iCloud-synced key library is
reachable across processes today.

## Architecture: a third layer

Every libssh2-touching file lives under `App/Sloop/`, which is the app target's
source list; the extension cannot link it. SloopKit cannot take it either —
Foundation-only and Linux-testable is load-bearing for `swift test` in CI.

So a third layer, built by XcodeGen as a framework both targets embed:

```
SloopKit (SPM, Foundation only, Linux CI)     ← unchanged
    ↑
SloopSSH (framework, requires CSSH)           ← new
    ↑                        ↑
App/Sloop (app)         App/SloopFiles (extension)   ← new
```

`App/SloopSSH/` receives, by move: `LibSSH2Transport`, `LibSSH2CommandRunner`,
`LibSSH2Error`, `TransportFactory`, `GenericPasswordStore`, the three keychain
stores, `TailscaleNode`, `TailscaleDialer`. UI stays in the app —
`HostKeyPrompter`, `TailscaleAuthPrompter`, every view.

Two seams must be cut for that move to be honest:

- **`TailscaleDialer` reaches into a UI singleton.** It calls
  `TailscaleAuthPrompter.shared.request(url)` from inside `dial()`. That
  becomes a `TailscaleAuthorizationPresenter` protocol: the app presents the
  sheet, the extension has no UI and turns it into an error.
- **`LibSSH2Transport.run()` inlines dial → handshake → verify → authenticate**
  before opening a shell channel. SFTP needs those same four steps and must not
  re-type them. They are extracted to a `LibSSH2Connection`; the transport
  opens a shell on it, the SFTP client opens a subsystem on it.

### The riskiest change is not the new code

It is that extraction. It is surgery on the dial/handshake/verify/auth path of
SSH *and* Mosh — code that is validated on device today and that everything
else in Sloop depends on. It lands as a behavior-preserving extraction,
verified by SSH and Mosh both still connecting on device, **before** any SFTP
code is written on top of it. If that regresses, nothing after it is
trustworthy.

## Shared state: App Group `group.org.szatmary.sloop`

Both targets gain the App Group entitlement.

**Files.** `HostStore` and `KnownHostsStore` take their directory from the App
Group container instead of Application Support. Migration on first launch is a
**file copy**, not a decode-and-re-encode: `HostStore` deliberately carries
records it cannot parse through a rewrite verbatim (a host written by a newer
build), and round-tripping them through this build's decoder during a migration
would quietly bypass the one protection that exists against losing them.

**Keychain.** `GenericPasswordStore` gains an `accessGroup` parameter, and
per-host credentials and Access tokens move into a **third** group,
`$(AppIdentifierPrefix)org.szatmary.sloop.fileprovider`, listed in both
targets' entitlements.

> **Correction, 2026-08-18.** The table above says these items live in the
> "default" access group, and the first implementation of the migration took
> that literally: it read *and deleted* them with no `kSecAttrAccessGroup` at
> all, meaning to name that group. A keychain query without one does not name a
> group — it matches **every group the process is entitled to**, and
> `SecItemDelete` removes every match. So the delete that was supposed to retire
> the original also removed the copy written one line earlier, destroying every
> saved password, key passphrase and Access token on the first launch after
> upgrading, while reporting a successful migration. Both stores now name their
> group explicitly, and the original is removed only after the new copy reads
> back. Found by review; nothing about it is visible from a build or a test run.

Reusing the existing `…sloop.shared` group would have been less work and is
wrong. That group is the iCloud-synced key library. Per-host passwords are
stored `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and deliberately
never leave the device; folding them into the synced group to solve a
process-boundary problem would change their sync posture as an invisible side
effect. Migration re-adds each item into the new group and deletes the old one.

The existing `AfterFirstUnlock` accessibility is exactly what a background File
Provider needs, and is free: a `WhenUnlocked` item would fail every time
Files.app touched it with the device locked.

**Keep the app's own group first** in the entitlements array. It is the default
group for any unscoped keychain call, and the ordering is load-bearing — see
the comment already in `Sloop.entitlements`.

## The SFTP layer

The terminal is testable because `Transport` is a protocol with the libssh2
implementation behind it. Same move, same payoff:

```swift
// SloopKit — Foundation only, no libssh2
public protocol SFTPClient: AnyObject {
    func list(_ path: String) throws -> [SFTPEntry]
    func stat(_ path: String) throws -> SFTPEntry
    func read(_ path: String, into: URL, progress: (Int64, Int64) -> Void) throws
    func write(_ url: URL, to path: String, progress: (Int64, Int64) -> Void) throws
    func makeDirectory(_ path: String) throws
    func remove(_ path: String) throws
    func rename(_ path: String, to: String) throws
}
```

`SFTPEntry` — name, size, mtime, POSIX mode, kind — is a plain struct in
SloopKit. `LibSSH2SFTPClient` implements the protocol in `SloopSSH` on top of
`LibSSH2Connection`.

The consequence worth stating: **the entire File Provider extension is written
against the protocol**, so it is unit-testable against an in-memory fake tree —
no server, no simulator, on Linux CI.

Sessions are pooled per host with a short idle timeout, and access to one
session is serialized: a libssh2 session is not thread-safe, and reconnecting
per operation would make every directory tap pay a full handshake and auth.

Transfers stream. `fetchContents` runs `libssh2_sftp_read` into a temp file in
chunks with `Progress` reporting; uploads stream the reverse. Nothing whole-file
in memory — a memory-capped extension and a multi-gigabyte download otherwise
end exactly one way.

## Item identifiers: the one genuinely hard part

`NSFileProviderItemIdentifier` must not change when an item is renamed or
moved. SFTP gives us paths, and a path *does* change on rename, so
path-as-identifier is wrong in a way that surfaces later as a corrupted replica
rather than as a build error.

So the extension owns one piece of durable local state: a per-domain map,
`UUID ↔ remote path`, at `fileprovider/<domain-id>/items.json` in the App Group
container (the domain id being the host's UUID). Enumeration mints an id for a
path it has not seen; rename rewrites the path under the existing id. Written
atomically — the map of a tree a user actually browses is on the order of a
megabyte, and it can become SQLite if that stops being true.

Losing the map is recoverable, not corrupting: ids are re-minted and the fix is
`NSFileProviderManager.reimportItems(below:)`.

> **Correction, 2026-08-18.** That claim was true of a *missing* map and false
> of a *malformed* one. `move` did not retire an identifier already sitting at
> the destination, so a rename onto a known path left two ids naming it;
> `modifyItem` saves immediately, so it reached disk; and `load` rebuilt the
> inverse map with `Dictionary(uniqueKeysWithValues:)`, which **traps** — inside
> `init`, where the `try?` guarding the decode cannot catch it. The domain then
> crashed on every launch until the file was deleted by hand, which is the
> opposite of recoverable. `move` now retires the displaced id, and `load` keeps
> one id per path instead of trapping, so the documented property holds for a
> corrupt file as well as an absent one. Both have regression tests.

## Change tracking without a change feed

SFTP has no notification channel, so `enumerateChanges(from:)` cannot be
event-driven. The identifier map earns its keep a second time: it stores each
listed directory's last-seen `(size, mtime)` per entry, and `enumerateChanges`
re-lists the directory and diffs against that snapshot, bumping a per-domain
anchor.

The honest consequence belongs in the docs, not a footnote: **changes made on
the server appear when Files.app refreshes, not the moment they happen.**
Pull-to-refresh works. Changes Sloop itself makes are signalled immediately. A
file changed by someone else over SSH shows up on the next enumeration.

## Tailscale: a second node

`TailscaleNode` is a singleton on purpose — "one node per app, not per host: a
tsnet node is a device on the tailnet with its own key and its own entry in the
admin console." Its state lives in the app container.

Two processes cannot share one tsnet state directory. The same node key on two
connections means the control plane sees one device flapping between two
endpoints. So the extension runs **its own node**, with its own state directory
in the App Group (`tailnet-files/` alongside the app's `tailnet/`) and its own
hostname (`sloop-<device>-files`), needing its own one-time authorization. It
appears as a second device in the admin console. That is the cost of the only
design that works while both processes are alive.

**This is gated.** Task 1 of the plan is a spike: a skeleton replicated
extension linking libssh2 and libtailscale, browsing a tailnet host, measuring
peak RSS and watching for jetsam. A 23 MB Go runtime inside a memory-capped
extension is a genuine open question, not a formality.

If it does not fit, tailnet hosts degrade to "not available in Files yet" with
the reason, and **nothing else in this design changes.** That is why the spike
goes first and why nothing is built on top of it until it answers.

## An extension cannot ask a question

Every interactive gate in the current SSH path becomes a typed refusal:

| Situation | Extension behavior |
| --- | --- |
| Host key not yet known | **Never TOFU.** A strict verifier that accepts only known keys. "Open Sloop and connect to this host once to trust its key." |
| Host key mismatch | Hard fail, no exceptions — same posture as `KnownHostsStore` today |
| Access token absent or expired | "Open Sloop to sign in to Cloudflare Access." |
| Tailnet device unauthorized | "Open Sloop to authorize this device on your tailnet." |
| Authentication rejected | "Sloop couldn't sign in to *host*." |

All surface as `NSFileProviderError.notAuthenticated`. When the app fixes the
cause it calls `signalErrorResolved`, so Files.app clears the banner instead of
making the user go and poke the folder again.

This is the one place the roadmap's standing complaint about `ConnectionState`
must not be repeated — *"stringifies at the boundary … nothing downstream can
tell a rejected credential from a dropped Wi-Fi link from a tunnel that wants a
browser login."* `SFTPError` stays typed all the way to the mapping table,
because here the distinction is not a nicety: it is the difference between five
words of instruction and a spinner.

### Correction, 2026-08-18: the mapping table does not speak POSIX

As designed and first implemented, that table mapped `SFTPError` to errno and
returned `NSPOSIXErrorDomain`, on the belief that Files.app acted on those codes
directly. **It does not.** `NSFileProviderReplicatedExtension` accepts errors in
`NSFileProviderErrorDomain` and `NSCocoaErrorDomain`, and classifies every other
domain — POSIX among them — as *transient*, retrying indefinitely.

So the design's whole argument for keeping the error typed was sound while its
conclusion was wrong: a file deleted on the server was never dropped from the
replica, a permissions refusal never reached the user, and a full filesystem
read as a glitch. Each case now maps to the domain the system actually reads
(`noSuchItem`, `filenameCollision`, `directoryNotEmpty`,
`NSFileReadNoPermissionError`, `NSFileWriteOutOfSpaceError`), and anything
unrecognized lands in `NSCocoaErrorDomain` rather than leaking a domain that
means "retry forever". `SFTPError.posixCode` still exists for callers that want
the POSIX reading; it is simply not what this boundary speaks.

Found by review, not by testing — the failure mode is an invisible retry loop,
which no build or unit test would have shown.

## Host model and UI

Two fields on `SSHHost`, both additive and safe against its existing
`decodeIfPresent` decoder:

- `showsInFiles: Bool` — flipping it on calls `NSFileProviderManager.add(domain:)`
  with the host's UUID as the domain identifier and its alias as the display
  name; flipping it off removes the domain.
- `filesRootPath: String?` — nil means the SFTP login directory.

Symlinks are followed and presented as their target. A broken one is an item
that fails on open rather than a lie in the listing.

## Packaging and builds

The extension target is declared in **`project.ssh.yml`**, not base
`project.yml`. Without libssh2 it is an extension that can only fail, and
registering its domain would put a permanently broken location in Files.app. In
the base build the "Show in Files" toggle is simply absent from the host
editor.

- `project.ssh.yml` — adds the `SloopFiles` extension target and the `SloopSSH`
  framework; both app targets embed them.
- `project.mosh.yml` — inherits unchanged. There is no Mosh in file transfer.
- `project.tailscale.yml` — adds `libtailscale` and `SLOOP_TAILSCALE` to the
  extension as well as the app.

## Testing

**Linux CI, `swift test`** — the identifier map (mint, rename, diff, anchor
bump), the change diff, path normalization, `SFTPEntry` attribute mapping, the
strict host-key verifier, and the `SFTPError` → `NSFileProviderError` table.

**Fake `SFTPClient`, in-memory tree** — drives the enumerator, item lookup, and
every create/modify/delete path. The extension's whole logic, no server, no
simulator.

**macOS `SloopTests`** — the `LibSSH2Connection` extraction as a regression
test, and the keychain access-group migration.

**On device** — {direct, Cloudflare Access, Tailscale} × {browse, download,
upload, rename, delete}, plus a multi-gigabyte file, plus access with the
device locked (the `AfterFirstUnlock` assumption), plus a jetsam watch
throughout.

## Order of work

1. **Memory spike** — skeleton extension, libssh2 + libtailscale, browse,
   measure. The only result that can change this design.
2. **`LibSSH2Connection` extraction** — behavior-preserving; SSH and Mosh
   verified on device before anything builds on it.
3. **`SloopSSH` framework** — the move, plus the `TailscaleAuthorizationPresenter`
   seam.
4. **App Group** — file migration, keychain group migration.
5. **`SFTPClient` + `LibSSH2SFTPClient`** — with the in-memory fake.
6. **Identifier map and change diff** — unit-tested standalone.
7. **The extension** — enumerators, item CRUD, streaming transfers, error
   mapping.
8. **Host model and UI** — the toggle, domain registration, `signalErrorResolved`.
9. **On-device validation.**

## References

- `Docs/ARCHITECTURE.md` — the `Transport` and `Dialer` seams this parallels
- `Docs/ROADMAP.md` — "SFTP / file transfer", and the `ConnectionState` typed-error entry
- `Docs/superpowers/specs/2026-08-12-tunnel-integrations-design.md` — the dialers reused here
