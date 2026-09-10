# Generating a key, and installing it on a host — design

**Status:** approved design, deferred until after v1 ships
**Date:** 2026-08-19

## What this builds

Two features that compose:

- **Generate** — Sloop creates an Ed25519 keypair on the device and puts it in
  the shared key library. The private half is never transported because it was
  never anywhere else.
- **Install** — Sloop appends any library key's public half to
  `~/.ssh/authorized_keys` on a saved host, the way `ssh-copy-id` does.

Together they close the loop that
[`2026-08-19-key-import-design.md`](2026-08-19-key-import-design.md) opens.
That spec moves an *existing* key onto the device; this one removes the need to.
Install is the more broadly useful of the two, because it works on imported keys
as well — updating `authorized_keys` across N servers is precisely the friction
that makes people transport private keys in the first place.

**Sequenced after v1** (decided 2026-08-19). Import ships first because it
serves the Windows and Linux users who prompted the work; this waits behind the
launch checklist in [`LAUNCH.md`](../../LAUNCH.md).

## Dependency on the import spec

Install needs the key's **public** half as an OpenSSH `.pub` line. Generated
keys have one by construction. Imported keys get one because the import spec's
`KeyValidator` populates `NamedKey.publicKey` on every path.

Library keys predating both — where `publicKey` is nil — derive one at install
time through the same validator. No third derivation path.

# Part 1 — Generation

## CryptoKit, not OpenSSL

The obvious route is `EVP_PKEY_keygen`. It is the wrong one here.

The `CSSH` module exposes exactly three headers: `libssh2.h`,
`libssh2_sftp.h`, and `libssh2-internal.h` — the last being Sloop's own
declarations for linkable-but-unpublished libssh2 symbols. OpenSSL's keygen API
is in none of them, so using it means adding more unpublished declarations to a
file whose own module map documents the hazard of it drifting from the
xcframework it describes.

`Curve25519.Signing.PrivateKey` generates an Ed25519 key with no new C surface
at all.

## The serialization is trivial, which is why Ed25519 only

The only work is producing a PEM that `_libssh2_pub_priv_keyfilememory` can
parse back. An unencrypted PKCS#8 Ed25519 private key (RFC 8410 §7) is a
**fixed 16-byte DER prefix followed by the 32-byte seed** — 48 bytes total:

```
30 2e                          SEQUENCE (46)
   02 01 00                    INTEGER 0                 -- version
   30 05                       SEQUENCE (5)              -- AlgorithmIdentifier
      06 03 2b 65 70           OID 1.3.101.112           -- Ed25519
   04 22                       OCTET STRING (34)
      04 20 <32-byte seed>     OCTET STRING (32)         -- CurvePrivateKey
```

Base64 it, wrap in `-----BEGIN PRIVATE KEY-----`, done.

The public line is equally mechanical — SSH wire format is a 4-byte big-endian
length before each field:

```
ssh-ed25519 <base64( "ssh-ed25519" ‖ raw-32-byte-public-key )> <name>
```

Both are pure byte manipulation, so **generation lives entirely in SloopKit**
and tests on Linux CI with no device, no libssh2 and no keychain.

This also settles the algorithm menu at **Ed25519 only**. ECDSA P-256 needs
curve OIDs and point encoding; RSA needs full DER and takes seconds to generate
on a phone. Ed25519 is the modern default, every OpenSSH since 6.5 accepts it,
and adding an algorithm later is purely additive. Offering three on day one
means three encoders to get wrong.

## Two independent derivations that must agree

SloopKit derives the public key from the private one by byte manipulation.
`KeyValidator` derives it through libssh2 and OpenSSL. A macOS test asserts they
produce the same line.

That is the whole acceptance test for the generator, and it is a real one: this
project has already shipped a crypto backend that parsed one key type and not
another. Two paths agreeing is evidence; one path succeeding is not.

## Generated keys carry no passphrase

Deliberate, and it follows from a finding recorded in
[`LAUNCH.md`](../../LAUNCH.md) §7: `NamedKey` stores the PEM and its passphrase
in **one** keychain item. Anything that can read the key can read the passphrase,
so a passphrase on a library key adds nothing at rest — the protection is
entirely the keychain's protection class.

Encrypting the generated key would mean hand-rolling PBKDF2 and AES inside a
PKCS#8 EncryptedPrivateKeyInfo structure, for a layer that demonstrably does no
work in the only place the key is stored.

**Revisit this if an export path is ever added.** A key leaving the device is
the case where its own encryption starts mattering, and there is no such path
today.

## Naming

Default to `sloop-ed25519`, editable before it is written.

Not derived from the device name: `UIDevice.current.name` returns a generic
model string on iOS 16+ without a special entitlement, so it would produce
`sloop-iPhone` on every iPhone the user owns and collide immediately.

Collision policy is unchanged and shared with every other import path — refused,
never overwritten, because the library syncs to devices that are not present to
object.

# Part 2 — Installing the key on a host

## The command

Run through `LibSSH2CommandRunner`, which already returns
`{stdout, stderr, exitStatus}`:

```sh
umask 077; mkdir -p ~/.ssh && { grep -qxF '<line>' ~/.ssh/authorized_keys 2>/dev/null \
  || printf '%s\n' '<line>' >> ~/.ssh/authorized_keys; }
```

Each piece earns its place:

- **`umask 077`** is load-bearing. sshd silently ignores an `authorized_keys`
  with group or world permissions, and a fresh `~/.ssh` created without it gets
  them. The resulting failure reads as "the key didn't work," which is the
  hardest kind to diagnose.
- **`grep -qxF`** makes re-running harmless. `-x` matches the whole line and
  `-F` treats it literally, so base64 containing regex metacharacters cannot
  produce a false match.
- **`printf '%s\n'`** rather than `echo`, whose handling of backslashes varies
  between shells.
- **A single small append** is effectively atomic on POSIX, so a dropped
  connection mid-write cannot leave a half-written key line.

The key line is user-influenced through the name in its comment field, so it is
**single-quote escaped** before interpolation. A key named `it's mine` must not
end the quoted string. This is tested explicitly.

## It cannot lock anyone out

Worth stating because it is the first question anyone sensible asks about an app
that writes to a security-critical file on their server: this operation only
ever *appends* an authorization. It does not remove keys, does not touch
`sshd_config`, and does not disable password authentication.

**Disabling password auth is deliberately not offered.** It is the one action
here that could lock a user out of their own machine, and an SSH client on a
phone is the worst possible place to do it — precisely because the phone might
be the thing that stops working.

## Verify, then switch

After the command succeeds, Sloop **opens a fresh connection authenticating
with the new key** before doing anything else. Only if that succeeds does it
offer to switch the host's `auth` to `.publicKey(name:)`.

A zero exit status proves a command ran. It does not prove sshd accepted the
file, which is a different claim and the one that matters — SELinux contexts,
an unexpected `AuthorizedKeysFile` setting, or a home directory on a filesystem
sshd distrusts all produce a clean exit and a key that does not work.

Given that this project has twice recorded a key as verified when it was not,
"we ran a command successfully" is not a standard worth adopting.

## Known limitations

- **Non-POSIX remotes.** Windows OpenSSH Server has no `umask` or `grep`, and
  keeps authorized keys at `%USERPROFILE%\.ssh\authorized_keys` — or, for
  administrators, `%PROGRAMDATA%\ssh\administrators_authorized_keys`. The
  command fails there. Detect the failure and say the host does not look like a
  POSIX shell, rather than reporting a generic error.
- **SELinux.** On RHEL-family hosts a freshly created `~/.ssh` can carry the
  wrong context, and sshd refuses it despite correct permissions. The verify
  step above catches it; the remedy is `restorecon -R ~/.ssh` on the host, and
  belongs in the error text.
- **A non-default `AuthorizedKeysFile`.** Writing to `~/.ssh/authorized_keys`
  is right for the overwhelming majority and wrong where sshd was reconfigured.
  Again caught by verification, not by prediction.

# Part 3 — The composed flow

On a host using password auth: **Set up key authentication**.

1. Generate a key, or pick an existing library key.
2. Install it (Part 2).
3. Verify by connecting with it.
4. Offer to switch the host to `.publicKey(name:)`.

Step 3 is not optional and step 4 is not automatic. The user is told what
happened at each stage, and a failure at 3 leaves the host exactly as it was —
still on password auth, with an extra authorized key that harms nothing.

## Errors

| Condition | What the user is told |
| --- | --- |
| Command exited non-zero | The remote's stderr, verbatim, plus the POSIX-shell hint when it looks like that. |
| Command succeeded, verification failed | The install worked but sshd did not accept the key, with the SELinux and `AuthorizedKeysFile` possibilities named. The host is left on password auth. |
| Key already present | Reported as already installed, not as an error. Re-running is a normal thing to do. |
| Name collides in the library | Rename offered; never an overwrite. |

## Testing

**SloopKit, Linux CI, no device:** PKCS#8 encoding pinned against RFC 8410 test
vectors; the SSH wire-format public blob; the derived `.pub` line; shell
escaping, including a key name containing a single quote.

**macOS test bundle:** a generated key round-trips through `KeyValidator`, and
the SloopKit-derived public line equals the libssh2-derived one. The install
command string is asserted against a fixture rather than executed.

**On a device, post-v1:** generate → install on a real password-auth host →
verification connect succeeds → host switches to key auth → reconnect from cold.
Added to [`LAUNCH.md`](../../LAUNCH.md) §6 when this is built, not before.

## Relationship to Secure Enclave

This is the on-ramp, and it is deliberately not the destination.

An SE key is P-256, non-exportable and device-bound, so it can never enter the
synced library ([`LAUNCH.md`](../../LAUNCH.md) §7). But the *install* half built
here is exactly what an SE key needs — a key generated on one device must be
enrolled on every host individually, and that is this feature. When SE keys are
built, they reuse Part 2 unchanged and only Part 1 differs.

That is the argument for building install even if generation were dropped.

## What this changes elsewhere

- `Docs/KEYS.md` — generation and install, and the fact that a generated key
  has no passphrase and why.
- `Docs/ROADMAP.md` — the `ssh-agent` / Secure Enclave nice-to-have gains a
  pointer here, since Part 2 is its prerequisite.
- `LAUNCH.md` §6 — two device checks, when built.
- Nothing in the import spec changes; this consumes `NamedKey.publicKey`, which
  that spec already populates.
