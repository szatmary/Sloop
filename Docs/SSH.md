# SSH: building and wiring libssh2

Sloop uses [libssh2](https://libssh2.org) for SSH. It's C, so it is built as a
multi-slice `.xcframework` and linked into the app target. `LibSSH2Transport`
is the Swift wrapper.

## 1. Build the xcframework

```sh
Scripts/build-libssh2.sh                       # all slices
SLICES="macos-arm64" Scripts/build-libssh2.sh  # one slice, for iteration
```

The script compiles everything from tagged source — nothing prebuilt enters the
tree — and writes `Vendor/libssh2.xcframework` (git-ignored; CI publishes it as
an artifact). Slices: `ios-arm64`, `ios-arm64-simulator`, `macos-arm64`, all
arm64. It merges `libssh2.a` and `libcrypto.a` into one static library per
slice so the xcframework is self-contained.

### The crypto backend: OpenSSL 3, not mbedTLS

libssh2 needs a crypto backend, and the choice is not cosmetic — it decides
which SSH key types work. Sloop used **mbedTLS** until 2026-08 and it caused
two real failures:

- **No Ed25519.** mbedTLS cannot parse an `ssh-ed25519` private key at all
  (`PK - Invalid key tag or value`), so the modern default key type was simply
  unusable.
- **No public-key derivation.** libssh2's mbedTLS backend cannot derive a
  public key from a private key in memory, so
  `libssh2_userauth_publickey_frommemory` fails unless the caller passes the
  `.pub` blob explicitly. Because the failure surfaced as the server's generic
  "Username/PublicKey combination invalid", it looked like a rejected key
  rather than a missing argument, and *every* key authentication failed.

**OpenSSL 3** handles Ed25519, ECDSA, and RSA (including `rsa-sha2-256/512`),
and derives public keys from private ones. It is Apache-2.0, compatible with
Sloop's GPL-3.0 (the old OpenSSL/GPL conflict was a 1.x licensing issue). It is
disclosed in `THIRD-PARTY-NOTICES.md`.

If you ever swap the backend again, re-run the key-type matrix in
`Docs/HANDOFF.md` ("Key types — required before release"). A backend can pass
every build and unit test while being unable to use half your keys.

### No tvOS slices

OpenSSL ships no tvOS `Configure` target, and the tvOS app is deferred anyway
(SwiftTerm doesn't compile for tvOS — see `Docs/ROADMAP.md`). If tvOS is
revived, tvOS slices need a custom OpenSSL configuration.

## 2. Make libssh2 importable as `CSSH`

The build script writes a `module.modulemap` into each slice's headers, so the
xcframework *is* the `CSSH` module — linking it is all that's needed to
`import CSSH`, no extra include paths.

That modulemap must name **both** `libssh2.h` and `libssh2_sftp.h`. `libssh2.h`
does not include the SFTP header, so a modulemap listing only the first leaves
every `libssh2_sftp_*` function and `LIBSSH2_SFTP_ATTRIBUTES` invisible to
Swift — and `LibSSH2SFTPClient`, which the whole Files.app integration rests
on, will not compile. An xcframework built before 2026-08-18 (or downloaded
from a CI run older than that) has the one-header version; either rebuild it
with `Scripts/build-libssh2.sh` or add the line by hand to each slice under
`Vendor/libssh2.xcframework/*/Headers/module.modulemap`.

Wiring is captured in `project.ssh.yml`, which layers the framework onto the base
project. With `Vendor/libssh2.xcframework` present:

```sh
xcodegen generate --spec project.ssh.yml
```

`App/Sloop/SSH/TransportFactory.swift` gates on `#if canImport(CSSH)`: with the
plain `project.yml` (no framework) it hands the UI a `MessageTransport`
explaining SSH isn't built yet; with the SSH spec, `CSSH` resolves and real
connections go through `LibSSH2Transport`. CI's `app-build-ssh` job downloads the
xcframework artifact and builds exactly this path.

## 3. LibSSH2Transport — already implemented

`App/Sloop/SSH/LibSSH2Transport.swift` implements the transport against the
stable libssh2 C API:

- non-blocking session driven by a `poll()` loop on a background thread;
- TCP connect via `getaddrinfo`;
- handshake, SHA-256 host-key check against `KnownHostsStore` (trust-on-first-use,
  refuse on mismatch);
- password and in-memory private-key auth;
- PTY shell channel; `send`/`resize`/read all serviced on the loop thread; only
  `onData`/`onClose` cross back to callers.

> It was authored without an Xcode/iOS SDK to compile against, so budget a
> first-build fix-up pass — mostly exact constant/typedef spellings the Swift C
> importer produces. The design (single-thread event loop, no cross-thread
> libssh2 calls) is intended to be kept.

Remaining wiring: a trust-on-first-use **prompt** (today unknown keys are
recorded and accepted) and key-based auth in the host editor UI.
