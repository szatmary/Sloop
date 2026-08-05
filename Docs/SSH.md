# SSH: building and wiring libssh2

Sloop uses [libssh2](https://libssh2.org) for SSH. It's C, so it must be built as
a multi-slice `.xcframework` and linked into the app target. `LibSSH2Transport`
is the Swift wrapper; today it reports `.notImplemented` until the binary and
implementation land.

## 1. Build the xcframework

libssh2 needs a crypto backend. On Apple platforms the simplest is to build
against a static OpenSSL (or use the system `Security`/`libssh2` if you prefer a
smaller footprint). Roughly:

```sh
# For each slice: ios-arm64, ios-arm64-simulator, macos-arm64, tvos-arm64,
# tvos-arm64-simulator — configure with the right SDK + arch, build static libs.
./configure --host=arm64-apple-darwin --with-crypto=openssl \
            --disable-shared --enable-static ...
make

# Then package all slices:
xcodebuild -create-xcframework \
  -library build/ios-arm64/lib/libssh2.a        -headers include \
  -library build/ios-sim-arm64/lib/libssh2.a    -headers include \
  -library build/macos-arm64/lib/libssh2.a      -headers include \
  -library build/tvos-arm64/lib/libssh2.a       -headers include \
  -output Vendor/libssh2.xcframework
```

Drop the result at `Vendor/libssh2.xcframework` (git-ignored) and add it to the
app target in `project.yml` under `dependencies:` as a `framework:`.

> Prebuilt options exist (e.g. the recipes in Blink's `build_frameworks`), but
> verify licensing and crypto export details before shipping.

## 2. Make libssh2 importable as `CSSH`

The build script writes a `module.modulemap` into each slice's headers, so the
xcframework *is* the `CSSH` module — linking it is all that's needed to
`import CSSH`, no extra include paths.

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
