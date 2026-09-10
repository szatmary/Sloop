# Getting a key into the library from Windows and Linux — design

**Status:** approved design, not yet implemented
**Date:** 2026-08-19

## What this builds

Two new ways to put an existing private key into the shared key library, for
people whose keys live on a machine Apple's ecosystem cannot reach: **pull it
from a host over SFTP**, and **import it from a file**. Both feed the same new
validation pipeline, which the two *existing* import paths — the `sloop` CLI
and the host editor's paste field — are refactored onto as well.

The net result is one way to get a key in, with four mouths, that verifies the
key parses before it is stored rather than discovering it doesn't at connect
time.

## The problem is transport, not iCloud

"Get keys into iCloud for Windows/Linux users" cannot be solved as stated.
There is no third-party keychain API on Windows and nothing at all on Linux;
a synchronizable keychain item is written by an entitled Apple-platform app or
not at all.

But it does not need to be solved as stated. `KeychainKeyStore` writes to a
synchronizable item, so **a key that reaches one Apple device reaches all of
them.** The host editor's paste flow
([`HostEditView.swift:458`](../../../App/Sloop/Views/HostEditView.swift#L458))
already writes a `NamedKey` into the library and already runs on iOS.

So the gap is narrow and concrete: getting one PEM onto one Apple device, once,
without routing a private key through email, a messaging app, or a notes sync.

## The shape

```
SFTP pull  (new) ─┐
File pick  (new) ─┼→ Data → PrivateKeyMaterial → KeyValidator → NamedKey → KeyStore
sloop CLI        ─┤                     ↑              │
Paste field      ─┘                     └── passphrase ┘
```

Only acquisition differs. Everything downstream is shared — which is the point.
Three of these four paths exist today with three different notions of what a
valid key is, and one of them (paste) has none at all.

### Layer split

| Piece | Where | Why there |
| --- | --- | --- |
| `PrivateKeyMaterial` | `Sources/SloopKit/Model/` | Foundation-only classification and naming. Tests on Linux CI with no device and no libssh2. |
| `KeyValidator` | `App/SloopSSH/` | Needs libssh2. Same directory, same `#if canImport(CSSH)` guard, as every other file that does. |
| The two new UI flows | `App/Sloop/Views/` | Ordinary SwiftUI. |
| In-memory SFTP read | `App/SloopSSH/LibSSH2SFTPClient.swift` | Extends what is already there. |

## `KeyValidator` — the piece that makes this worth doing

libssh2 exposes `_libssh2_pub_priv_keyfilememory`, already wrapped in this
codebase at
[`AgentSigner.swift:54`](../../../App/SloopSSH/AgentSigner.swift#L54):

```c
_libssh2_pub_priv_keyfilememory(session,
                                &method, &methodLength,   // "ssh-ed25519", 11
                                &blob, &blobLength,       // SSH wire-format public key
                                pem, pemLength,
                                passphrase);              // NULL or a C string
```

One call answers four questions:

1. **Does this parse?** `rc == 0` or it doesn't.
2. **Is it encrypted?** A parse failure with no passphrase supplied means it
   needs one (or is corrupt — see Errors below).
3. **Is the passphrase right?** A parse failure *with* one supplied means it
   isn't.
4. **What is the public key?** `method` + `blob`, which is exactly what
   `NamedKey.publicKey` wants.

`NamedKey.publicKey` is documented as an OpenSSH `.pub` line, so the blob is
converted rather than stored raw:

```
<method> <base64(blob)> <name>
```

### What this deletes

[`KeyCLI.isEncryptedPEM`](../../../App/Sloop/KeyCLI.swift#L119) is **removed,
not improved.** It decides whether to prompt for a passphrase by searching for
the literal string `ENCRYPTED` and for `bcrypt` in the base64-decoded body,
which misses an OpenSSH-format key using any other KDF and matches `ENCRYPTED`
appearing anywhere, including in a comment.

Guessing is the wrong shape for this question. Attempting the parse is the
answer, and it is available. The heuristic goes away rather than acquiring a
third case.

### The one gate to verify first

`_libssh2_pub_priv_keyfilememory` takes a `LIBSSH2_SESSION *`. `AgentSigner`
has a live one because it runs inside a connection; the validator will create
one with `libssh2_session_init()` and never connect it.

**This must be confirmed before the rest is built.** libssh2 uses the session
for its allocator and error state, not for I/O, so an uninitialized session
should be sufficient — but "should be" is not a design. If it is not
sufficient, the validator needs a different primitive and this spec needs
revisiting; there is no fallback worth writing, because a validator that
sometimes doesn't validate is worse than none.

## Source A — pull the key from a host

**Entry point:** the key library screen, *Import from a host*, choosing from
saved hosts. Not the terminal's menu.

Two reasons. It is where the user already is when their intent is "add a key,"
and reusing a live terminal session would couple the key library to session
state. It costs one connection, and `SFTPClientFactory` already establishes one
independently of any terminal — the File Provider extension does exactly this.

**Flow:** connect → `readdir("~/.ssh")` → filter → picker → in-memory read of
the *one* file the user picked → pipeline.

Whatever auth the saved host already uses applies; nothing new is needed here.
Password auth is simply the case that matters most, because a user reaching for
this feature is by definition someone who does not yet have a key on the
device.

**Filter by name, not by content.** Exclude `*.pub`, `known_hosts*`, `config`,
`authorized_keys*`, `environment`, `rc`. Show everything else and let the
validator judge after selection.

The alternative — peeking inside each file to classify it — would mean pulling
every private key in the directory off the server to decide what to show. That
is precisely the thing this feature must not do speculatively.

**The read must not touch the filesystem.**
[`LibSSH2SFTPClient.read(_:into:)`](../../../App/SloopSSH/LibSSH2SFTPClient.swift#L175)
writes to a destination `URL`, which is right for the File Provider and wrong
here. This adds an in-memory sibling. A private key written to disk, even
briefly, even in a container, is a new exposure this design has no reason to
create.

**A confirmation that says what is happening.** Not a generic "are you sure":
it names the host and states that the private key is being copied from it onto
this device. Making key extraction from a server frictionless is the one
genuine hazard in this feature, and the mitigation is that the user knows they
did it. Fine for your own box; worth a pause on a shared one.

## Source B — import from a file

**Entry point:** the key library screen, *Import from Files*.

`.fileImporter` → security-scoped URL → read into memory → pipeline. The
cheapest of the two by a wide margin.

Covers iCloud Drive — which **is** what iCloud for Windows syncs, and is
therefore the Windows story — plus USB drives on iPad, AirDrop, and SMB shares.

**The iCloud Drive caveat belongs in the UI.** A private key at rest in iCloud
Drive is not end-to-end encrypted unless the user has Advanced Data Protection
enabled, which most do not. That is a real downgrade from the keychain the key
is headed for. After a successful import from a file, say so, and say to delete
the source. Documenting it only in `Docs/KEYS.md` puts the warning where the
users routed toward this path are least likely to look.

## Naming and collisions

Shared by all four paths, and unchanged from what `sloop import-key` already
enforces:

- Default name from the source: the filename for A, B and the CLI; the existing
  field for paste.
- **A collision is refused, never overwritten.** The library syncs to every
  device, so a silent overwrite destroys key material on machines that are not
  present. The CLI's `--force` remains the only way through, and the UI paths
  get an explicit rename prompt instead.

## Errors

Typed, and specific enough to act on. `KeyAuthFailure` in SloopKit already
carries this exact reasoning for the connect-time case and its message logic is
reused rather than re-derived:

| Condition | What the user is told |
| --- | --- |
| Not a private key at all (`.pub`, `known_hosts`, binary) | What it looks like instead, named. |
| Parse failed, no passphrase supplied | Prompt for a passphrase and retry. Note this is also what a *corrupt* unencrypted key produces, so a truncated key costs the user one wasted passphrase attempt before the message below. Accepted: the alternative is guessing, which is what this design removes. |
| Parse failed, passphrase supplied | Wrong passphrase, or the key is unreadable. Both, because libssh2 does not distinguish them and claiming otherwise would be a guess. |
| Name already in the library | Offered a rename; never an overwrite. |
| Keychain refused the write | The existing `KeychainKeyStore` error, which already explains the signing cause. |

## Testing

**SloopKit, on Linux CI, no device:** `PrivateKeyMaterial` classification
across Ed25519, ECDSA, RSA and OpenSSH formats, encrypted and not; rejection of
`.pub` files, `known_hosts`, empty input and binary noise; name derivation and
collision policy.

**macOS test bundle:** `KeyValidator` against fixture keys of all three types,
encrypted and not, with correct and incorrect passphrases, plus corrupt input.
This is where the `isEncryptedPEM` gap gets pinned so it cannot come back.

**On a device**, added to [`LAUNCH.md`](../../LAUNCH.md) §6: both flows end to
end, including a passphrase-protected key — which is the case the existing
key-type verification never exercised through the app.

## What this changes elsewhere

- `Docs/KEYS.md` — a new section on the import paths, including which one to
  use from Windows versus Linux.
- `Docs/LAUNCH.md` §6 — the two new device checks.
- `KeyCLI.swift` — `isEncryptedPEM` deleted; the CLI routes through
  `KeyValidator` and gains validation it does not have today.
- `HostEditView.swift` — the paste flow routes through the pipeline, so pasting
  something that isn't a key fails at import with a clear message instead of at
  connect, hours later, as an authentication failure.
- `AgentSigner.withOptionalPassphrase` — currently private, moves somewhere both
  it and `KeyValidator` can reach.

## Deferred

**QR scan.** Designed and set aside on 2026-08-19: the air-gapped path, with
the desktop side documented as `qrencode -t ANSIUTF8 < ~/.ssh/id_ed25519`
rather than shipped as a tool, and deliberately single-frame — Ed25519, ECDSA
and RSA-2048 fit under a QR's ~2.9KB binary ceiling; RSA-4096 does not, and
`qrencode` refuses it on the desktop where the user can act on the error.

Held back because it needs `NSCameraUsageDescription` and a camera permission
prompt, which is new App Store review surface on an SSH client for the smallest
coverage gain of the three. A and B cover Linux and Windows respectively without
it.

**On-device key generation.** The security-correct answer — a keypair generated
on the phone whose private half never moves — and the natural on-ramp to Secure
Enclave keys ([`LAUNCH.md`](../../LAUNCH.md) §7). It is a different feature, not
a variant of this one: it needs UI for getting a *public* key onto N servers,
which is the friction that makes people transport private keys in the first
place. Sequenced after this because a user with twenty existing hosts is served
today by transport and not at all by generation.
