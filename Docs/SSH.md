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

## 2. Implement LibSSH2Transport

Fill in the `TODO(ssh)` markers in
`Sources/SloopKit/SSH/LibSSH2Transport.swift`:

1. `start()` — open a TCP socket, `libssh2_session_init`,
   `libssh2_session_handshake`.
2. Verify the host key against a `known_hosts` store; trust-on-first-use prompt.
3. Authenticate per `host.auth` using the `Credential`
   (`libssh2_userauth_password` / `..._publickey_frommemory`).
4. `libssh2_channel_open_session`, `request_pty("xterm-256color")`,
   `channel_shell`.
5. Spin a background read loop → `onData`; `send` → `libssh2_channel_write`;
   `resize` → `libssh2_channel_request_pty_size`.

Keep all libssh2 calls on the transport's serial queue; only `onData`/`onClose`
cross back to callers.
