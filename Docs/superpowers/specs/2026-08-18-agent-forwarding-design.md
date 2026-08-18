# SSH agent forwarding — design

**Status:** approved design, not yet implemented
**Date:** 2026-08-18

## What this builds

Sloop acts as an SSH agent for hosts it connects to. A remote shell running
`ssh`, `git`, or `scp` can ask Sloop to sign an authentication challenge with a
private key that never leaves the device, so hopping from a connected host to a
third one works without copying a key onto the intermediate machine.

Two properties are non-negotiable and shape everything below:

- **Every signature is confirmed by the user**, showing which key and which
  host. Agent forwarding hands a remote machine the ability to authenticate as
  you; anyone with root there can use the socket for as long as the connection
  lives. A prompt is the difference between that being a thing you allow and a
  thing that happens to you.
- **Only keys chosen for that host are exposed.** The identity list is handed
  over before anything is signed, and it is a map of every system you hold a key
  for.

Note for the reader deciding whether to use this: for the common case of
reaching a third host, `ProxyJump` is the safer tool and is separately on the
roadmap. Forwarding earns its place when the remote side must run the SSH
client itself — `git push` from a build box, an `scp` between two remotes.

## What libssh2 gives us, and what it doesn't

The vendored build is 1.11.1_DEV with the OpenSSL 3 backend.

`libssh2_channel_request_auth_agent()` is public and present in the shipped
`.a`, so asking the server to forward is one call. When the server opens an
`auth-agent@openssh.com` channel back, libssh2 accepts it, allocates the
channel, and invokes the `LIBSSH2_CALLBACK_AUTHAGENT` callback
(`src/packet.c:589`) — and stops.

The `LIBSSH2_CALLBACK_AUTHAGENT_IDENTITIES` and
`LIBSSH2_CALLBACK_AUTHAGENT_SIGN` callbacks look like they would do the rest.
They do not. Their macros are defined in `src/libssh2_priv.h` and **invoked
nowhere in libssh2's sources**; the only references are the setter cases in
`session.c`. They exist for consumers of libssh2's server-side API.

So libssh2 hands us a channel and nothing else. Framing, the agent protocol,
identity enumeration, and signing are all ours.

## Signing engine: libssh2's internal crypto

The deciding constraint is the private-key container. Modern `ssh-keygen`
always emits `-----BEGIN OPENSSH PRIVATE KEY-----`, and Ed25519 keys have never
used any other format.

| Candidate | Verdict |
|---|---|
| CryptoKit / Security | Cannot read the OpenSSH container. Neither framework covers all three key types (no RSA in CryptoKit, no Ed25519 in Security). Would require writing the container parser *and* bcrypt_pbkdf. |
| OpenSSL 3 directly | Symbols are exported from the vendored `.a`, but OpenSSL does not read the OpenSSH container either. Same parser problem. |
| **libssh2's internal crypto** | Already parses the container, already handles passphrases, already covers RSA/ECDSA/Ed25519. It is the code path that authenticates hosts today. |

libssh2's internals win. The cost is real and stated plainly: these are
`_libssh2_*` functions declared in `src/crypto.h`, not in the public
`libssh2.h`. We declare the prototypes ourselves and depend on internals that
can change on upgrade.

The mitigation is a test that signs and then verifies through the matching
`_libssh2_*_verify`, per key type. If a prototype drifts, the suite fails
loudly instead of the app producing signatures that a remote silently rejects.
Verified present as `T` symbols in `Vendor/libssh2.xcframework/ios-arm64/libssh2.a`:

```c
int _libssh2_pub_priv_keyfilememory(LIBSSH2_SESSION *session,
                                    unsigned char **method, size_t *method_len,
                                    unsigned char **pubkeydata, size_t *pubkeydata_len,
                                    const char *privatekeydata, size_t privatekeydata_len,
                                    const char *passphrase);

int _libssh2_ed25519_new_private_frommemory(libssh2_ed25519_ctx **ctx, LIBSSH2_SESSION *s,
                                            const char *filedata, size_t filedata_len,
                                            unsigned const char *passphrase);
int _libssh2_ed25519_sign(libssh2_ed25519_ctx *ctx, LIBSSH2_SESSION *session,
                          uint8_t **out_sig, size_t *out_sig_len,
                          const uint8_t *message, size_t message_len);

int _libssh2_rsa_new_private_frommemory(libssh2_rsa_ctx **rsa, LIBSSH2_SESSION *s,
                                        const char *filedata, size_t filedata_len,
                                        unsigned const char *passphrase);
int _libssh2_rsa_sha2_sign(LIBSSH2_SESSION *session, libssh2_rsa_ctx *rsactx,
                           const unsigned char *hash, size_t hash_len,
                           unsigned char **signature, size_t *signature_len);

int _libssh2_ecdsa_new_private_frommemory(libssh2_ecdsa_ctx **ctx, LIBSSH2_SESSION *s,
                                          const char *filedata, size_t filedata_len,
                                          unsigned const char *passphrase);
int _libssh2_ecdsa_sign(LIBSSH2_SESSION *session, libssh2_ecdsa_ctx *ctx,
                        const unsigned char *hash, size_t hash_len,
                        unsigned char **signature, size_t *signature_len);
```

### Where the public-key blob comes from

`REQUEST_IDENTITIES` must answer with each key's wire-format public blob.
`NamedKey.publicKey` cannot supply it: the iOS import path in
`HostEditView.swift:320` constructs `NamedKey` without one, so on iPad — the
primary platform — every library key has `publicKey == nil`. Requiring a stored
`.pub` would forward nothing at all on the device this feature is for.

`_libssh2_pub_priv_keyfilememory` derives both the algorithm name and the blob
from private key data in memory. It is the same function
`libssh2_userauth_publickey_frommemory` uses when the caller supplies no public
key, which is exactly how key auth already works on iOS today. This removes the
need for any key-derivation code of our own.

### Signature blob format

All three key types produce the same outer shape — `string algorithm`, then
`string signature-bytes` — because libssh2's signers already emit the inner
payload the wire wants:

| Algorithm | Inner bytes from libssh2 |
|---|---|
| `ssh-ed25519` | raw 64-byte signature |
| `rsa-sha2-256` / `rsa-sha2-512` | raw RSA signature |
| `ecdsa-sha2-nistp*` | `mpint r ‖ mpint s`, already formatted by `write_bn` (`openssl.c:3007-3009`) |

RSA and ECDSA sign a hash, not the message. CryptoKit supplies it —
`SHA256`/`SHA384`/`SHA512` — rather than reaching for another internal symbol.
The RSA digest is chosen by the request's flags (`SSH_AGENT_RSA_SHA2_256 = 2`,
`SSH_AGENT_RSA_SHA2_512 = 4`); the ECDSA digest follows the curve.

**A request with neither RSA flag set is refused.** Bare `ssh-rsa` is
SHA-1-signed, rejected by default by OpenSSH 8.8 and later, and there is no
reason to add a SHA-1 signing path to a 2026 client.

## File structure

The protocol is byte manipulation with no platform dependency, so it lives
where it can be tested on Linux CI without a device or a network — the same
split that put `SSHURL` in SloopKit and libssh2 in the app target.

| File | Responsibility |
|---|---|
| `Sources/SloopKit/SSH/AgentProtocol.swift` | Frame and parse agent messages. Foundation-only. No knowledge of keys or libssh2. |
| `Sources/SloopKit/SSH/AgentIdentity.swift` | One exposed key: algorithm, public blob, comment, originating `NamedKey` name. |
| `App/Sloop/SSH/AgentSigner.swift` | Blob → matching key → signature, via the libssh2 internals above. |
| `App/Sloop/SSH/ForwardedAgent.swift` | Owns the agent channel: reads frames, dispatches, writes replies. |
| `App/Sloop/SSH/AgentSignPrompter.swift` | Per-signature confirmation, mirroring `HostKeyPrompter`. |
| `App/Sloop/SSH/libssh2-internal.h` | The prototypes above, declared for Swift. Included from `Sloop-Bridging-Header.h`, **not** exposed as a module map — `Sloop-Bridging-Header.h:15-17` records why: Xcode copies every xcframework's headers into one `include/` directory, where a second `module.modulemap` collides with the one libssh2 ships. Same reason `tailscale.h` is bridged rather than moduled. |

Model and UI:

- `SSHHost.forwardedKeys: [String]` — names of library keys exposed to this
  host. Empty means forwarding is off. One field rather than a `Bool` plus a
  list, so there is no state where the two can contradict each other.
- `HostEditView` — the forwarding row expands to a checklist of library keys.
- `TransportFactory` — already resolves a `Credential`; grows a parallel
  resolve of the forwarded `NamedKey` set from `KeyLibrary`.

## Build integration (a trap found while writing this)

`Sloop-Bridging-Header.h:5-8` claims "Only the SSH-enabled project
(project.ssh.yml) sets `SWIFT_OBJC_BRIDGING_HEADER` to this file." **That is not
true.** The only spec that sets it is `project.mosh.yml` (lines 27 and 38);
`project.ssh.yml` does not. Nothing has noticed because the bridging header's
only current contents are the Mosh and Tailscale surfaces, which are used in
exactly the variants that do set it.

Putting the libssh2 internal prototypes there without fixing this would make
agent forwarding compile only in the Mosh build. So:

- `project.ssh.yml` must set `SWIFT_OBJC_BRIDGING_HEADER` on both app targets.
- `#import "MoshBridge.h"` becomes `__has_include`-guarded, matching the
  treatment `tailscale.h` already gets one line below it. It is a
  declarations-only C header, so including it in an SSH-only build is harmless
  — but the guard keeps the header honest about what each variant provides.
- The stale comment gets corrected in the same change.

The app-target tests live in `Tests/SloopAppTests` and run under the
`Sloop_macOS` scheme. Since `project.ssh.yml` includes `project.yml`, that
bundle exists in the SSH variant too. The sign-then-verify tests are gated
`#if canImport(CSSH)`, exactly as `LibSSH2Transport.swift:15` gates its source,
so the plain no-SSH build still compiles and tests cleanly.

## Message flow

1. After `libssh2_channel_process_startup`, if `host.forwardedKeys` is
   non-empty, call `libssh2_channel_request_auth_agent`.
2. The remote opens `auth-agent@openssh.com`; libssh2 calls our
   `LIBSSH2_CALLBACK_AUTHAGENT` with the new channel.
3. `ForwardedAgent` takes ownership and services it in the existing
   non-blocking loop.
4. `REQUEST_IDENTITIES (11)` → `IDENTITIES_ANSWER (12)` listing only the keys
   selected for this host, each as `string blob`, `string comment` (the key's
   library name).
5. `SIGN_REQUEST (13)` → match the blob to a selected key; if none matches,
   `SSH_AGENT_FAILURE (5)`. Otherwise prompt the user, blocking the SSH thread
   on a semaphore.
6. Confirmed → sign, reply `SIGN_RESPONSE (14)`. Refused → `SSH_AGENT_FAILURE`,
   which is an ordinary answer a remote client handles as "that key didn't
   work".
7. Any other request type → `SSH_AGENT_FAILURE`. Sloop implements no key
   management over the wire: adding, removing, or locking keys is the app's
   job, not a remote host's.

### The confirmation prompt

`HostKeyPrompter.swift:51-66` already blocks the SSH thread on a
`DispatchSemaphore` while the UI asks a question, and documents the
happens-before ordering that makes it safe. `AgentSignPrompter` mirrors it
exactly. This is a known pattern in this codebase, not new machinery.

The prompt must name the key and the host, because that is the only
information distinguishing a signature the user just caused from one a
compromised remote initiated on its own.

## The risky part: two channels in one loop

`LibSSH2Transport.swift:296-325` services exactly one channel non-blocking. It
must now service two without agent traffic stalling the shell or the reverse.
This is the part most likely to be wrong, and the reason `ForwardedAgent` is a
separate type with a narrow interface — `readable()`, `writable()`, `close()` —
rather than logic inlined into the existing loop.

Both channels are on one SSH session, so all libssh2 calls stay on the existing
SSH thread. The prompt's semaphore wait is the one place that thread blocks;
the shell is unresponsive for that interval by design, since the alternative is
signing without asking.

## Limitations, stated up front

- **Mosh sessions cannot forward.** SSH is only the bootstrap that launches
  `mosh-server`; the session that carries the terminal is not an SSH connection
  and has no channel to forward over. The UI must not offer forwarding for a
  Mosh host rather than offering it and silently doing nothing.
- **No round-trip test without a real host.** As with the Cloudflare Access
  work, unit tests prove the bytes and the signatures; they cannot prove a real
  `ssh` on a real remote accepts them. This needs an entry in
  `Docs/HANDOFF.md` alongside the existing device checklist.
- **No `SSH_AGENT_CONSTRAIN_*` support.** Constraints are a property of keys
  added to an agent; nothing can be added to this one.

## Testing

In SloopKit, running on Linux CI:

- Golden byte vectors for `REQUEST_IDENTITIES` and `SIGN_REQUEST` parsing, and
  for `IDENTITIES_ANSWER` / `SIGN_RESPONSE` construction.
- Truncated frames, a length header longer than the payload, a length header
  large enough to be an allocation attack, zero-length payload, and unknown
  request types — each must produce a refusal or a parse error, never a crash
  and never an unbounded allocation.
- An identities answer for an empty key set (a valid answer with count zero).

In the app target:

- Sign, then verify through the matching `_libssh2_*_verify`, for Ed25519, RSA
  (both SHA-2 sizes), and ECDSA. This proves the signature is real rather than
  merely non-empty, and is the tripwire for internal-prototype drift.
- A `SIGN_REQUEST` for a blob that is not in the host's selected set returns
  `SSH_AGENT_FAILURE` without prompting.
- A refused prompt returns `SSH_AGENT_FAILURE`.
- A bare `ssh-rsa` request with no SHA-2 flag is refused.

## Open item deferred deliberately

Nothing in this design covers *revoking* forwarding mid-session. If a user
wants to stop, they disconnect. Adding a live toggle means tearing down a
channel the remote believes is open, and the failure modes are worse than the
feature is worth at v1.
