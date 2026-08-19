# Launch readiness

_Opened 2026-08-19. The authoritative checklist for getting Sloop into the App
Store._

This is the one list. [`ROADMAP.md`](ROADMAP.md) M4 points here rather than
keeping its own copy — overlapping ship lists is how all of them end up wrong.
`Docs/HANDOFF.md` was the previous attempt and was deleted on 2026-08-19 after
it drifted into contradicting itself about which key types had been verified;
its durable content moved to [`KEYS.md`](KEYS.md) and [`SIGNING.md`](SIGNING.md).

Legend: `[ ]` open · `[x]` done · `[?]` **claimed done but disputed — do not
trust without re-verifying**.

## Decisions taken

- **2026-08-19 — iOS to the App Store, macOS via Developer ID direct
  download.** The consequence that matters: the Mac App Store would require
  App Sandbox, which neither [`Sloop.entitlements`](../App/Sloop/Sloop.entitlements)
  nor [`SloopFiles.entitlements`](../App/SloopFiles/SloopFiles.entitlements)
  has, and which would break the `Scripts/sloop` CLI and put tsnet's socket
  behavior in question. Developer ID sidesteps all of it for v1. Revisit for
  v2 if Finder/SFTP integration or automatic updates justify the work.
- **2026-08-19 — the tip jar is hidden for v1.** Worth more than the revenue:
  it drops the Paid Applications agreement, banking details and tax forms out
  of App Store Connect, which is the one prerequisite with an unbounded,
  human-gated wait. Code stays in `App/Sloop/Store`; only the entry point goes.
  See [`TIPJAR.md`](TIPJAR.md).
- **GPL-3.0 with Mosh bundled**, corresponding source kept public — the
  reasoning is in [`LICENSING.md`](LICENSING.md). **Still needs your explicit
  sign-off** on the residual risk (a Mosh copyright holder objecting to App
  Store distribution). It is a judgment call, not a file.

## 1. Blocks the upload

Apple rejects the binary or App Store Connect refuses it. None of these are
discretionary.

- [ ] **Privacy manifest.** No `PrivacyInfo.xcprivacy` exists in the app or the
      File Provider extension; required since May 2024, and each bundle needs
      its own. Required-reason APIs in use: `UserDefaults` in
      [`AppearanceStore.swift`](../App/Sloop/Views/AppearanceStore.swift) and
      [`HostListModel.swift`](../App/Sloop/Views/HostListModel.swift)
      (category CA92.1), plus file-timestamp APIs in the extension. Also
      declares the "no data collected" posture.
- [ ] **Export compliance.** No `ITSAppUsesNonExemptEncryption` in the shared
      plist block ([`project.yml:113`](../project.yml#L113)). `false` is not
      honestly available — SSH crypto is the product, not incidental HTTPS.
      Path: self-classify under the open-source/TSU exemption (notification
      email to BIS and NSA) or obtain an ERN, then set the key and
      `ITSEncryptionExportComplianceCode`. **Longest lead time on this page.
      Start it first**; until it is in the plist every single upload prompts.
- [ ] **Developer portal registration.** Distribution profiles will not build
      without these, and automatic signing does not create them: the
      `.fileprovider` bundle ID, the app group `group.org.szatmary.sloop`, the
      keychain groups `…sloop.shared` and `…sloop.fileprovider`, and an iOS
      distribution certificate + provisioning profile.
- [ ] **There is no release build spec.** `project.yml`, `project.ssh.yml`,
      `project.mosh.yml` and `project.tailscale.yml` are four variants, and
      none of them has SSH + Mosh + Tailscale + the File Provider extension
      together. Nothing else on this page can be built until one does.
- [ ] **Version is `0.1.0` / `1`**, written in three separate places across the
      specs. Collapse to one definition and bump to `1.0.0`.

## 2. Blocks review

The binary uploads; a human then rejects it.

- [ ] **A host the reviewer can actually connect to.** Sloop opens to an empty
      host list and does nothing else without one — this is the standard
      rejection for SSH clients. Stand up a throwaway host with a restricted
      shell and `mosh-server` installed, and put the credentials in the App
      Review notes.
- [ ] **Age rating.** `AccessLoginView` is a `WKWebView` that loads a hostname
      the user types, which reads as unrestricted web access on the
      questionnaire and pushes toward 17+. Decide the answer deliberately —
      discovering it during review costs a cycle, and answering it wrong costs
      a removal later.
- [ ] **Guideline 2.5.2 (executable code).** An SSH client is fine: the code
      runs on the remote host and is never downloaded to the device. Have the
      sentence written before you need it.
- [ ] **The repo must be public at ship.** [`LICENSING.md`](LICENSING.md) rests
      the entire GPL/App Store posture on corresponding source being available
      to every App Store user; the repo is currently private (CI runs on a
      daily schedule partly because private macOS minutes bill at 10×). Flip
      it, and tag each release so the source matches the shipped binary.

## 3. Store listing

- [ ] **Privacy policy URL** — mandatory for every app. Does not exist.
- [ ] **Support URL** — mandatory. Does not exist. GitHub Pages off the repo
      covers both.
- [ ] **Screenshots** at iPhone 6.9" and iPad 13". No marketing assets exist.
      (The app icon itself is done — `Scripts/generate-appicon.sh`.)
- [ ] **Privacy questionnaire** — "Data Not Collected" throughout. Sloop's
      command suggestions, host list and keys never leave the device; key
      material syncs only through the user's own iCloud Keychain, E2E
      encrypted, which is not collection.
- [ ] **A TestFlight build**, installed and run from TestFlight, before
      submitting for review.

## 4. macOS (Developer ID)

- [ ] **Store the `sloop-notary` credential** — the command is in
      [`SIGNING.md`](SIGNING.md#L69). Nothing notarizes until it exists.
- [ ] **Run notarization end to end.** [`SIGNING.md`](SIGNING.md) records
      signing as verified 2026-08-17 but notarization as never having run.
- [ ] **Decide the CI question** — export the Developer ID profile as a repo
      secret, or keep cutting Mac releases from this Mac with
      `Scripts/sign-release.sh`. Either is fine; drifting between them is not.

## 5. Build configuration

- [ ] **`NSLocalNetworkUsageDescription` is absent** and tsnet does LAN peer
      discovery. Verify on a device: a missing purpose string is a process
      termination, not a permission denial.

## 6. On-device verification

The real quality gate. Every serious defect this project has hit was invisible
to the compiler, the unit tests and CI alike: a public key never passed to
libssh2 (so *all* key auth failed), a frozen clock that let Mosh send exactly
one packet per session, and a "C" locale that truncated every multi-byte
character to its lead byte. Assume the same of everything still unchecked.

**Core terminal**

- [ ] **Agent forwarding** — never run against a real remote. On a host with
      keys selected in Forward Agent, run `ssh-add -l` on the remote and then
      an `ssh`/`git` operation that uses the key: each signature must raise the
      confirmation sheet, and refusing must fail that operation rather than the
      session.

- [ ] SSH **password** login to a real host; interactive shell; resize works.
- [ ] **Host-key prompt** on an unknown host, and mismatch refused.
- [ ] **Mosh roaming** — drop Wi-Fi to cellular mid-session, confirm resume.
- [ ] **Mosh fallback** to SSH on a host without `mosh-server`, with the notice.
- [ ] **Two Mosh sessions** to one host at once.
- [x] **Mosh over the tailnet** — verified on an iPad against zbox, 2026-08-19:
      probe over tsnet, `mosh-server` started, SSP flowing (the no-packet
      notice never fired).
- [ ] **Tabs**: several open, switching, background tabs stay connected,
      ⌘T/⌘W/⌘⇧[ ] on iPad and Mac.
- [ ] **Appearance**: font/theme/cursor apply live and survive relaunch.
- [ ] **SSH config** import and export round-trips.

**Key types — the state of this is disputed; resolve before anything else here**

Each supported key type must authenticate **end to end, on device, against a
real server**. Do not treat "the app connected" as covering all of them: the
crypto backend implements each key type separately, and Sloop has already
shipped a backend (mbedTLS) that could not parse Ed25519 keys at all while RSA
worked fine.

The predecessor of this file recorded these three as both verified and never
verified, in two lists a dozen lines apart. What the 2026-08-18 run genuinely
proved, by its own description, was the **crypto backend** — a direct
`libssh2_userauth_publickey_frommemory` call with the same argument order the
transport uses. It did not exercise the app.

- [?] **RSA on device**, 2026-08-17. Open question raised 2026-08-19: if that
      host also accepts password auth, the session may have authenticated by
      password and the key result is a false positive. Re-run isolated, below.
- [?] **Ed25519 / ECDSA** — crypto backend proven, app path not.
- [?] **Passphrase-protected key** — crypto backend proven, app path not. The
      passphrase crosses five hops before reaching the call that was proven:
      [`HostEditView.swift:212`](../App/Sloop/Views/HostEditView.swift#L212) →
      [`:461`](../App/Sloop/Views/HostEditView.swift#L461) → one JSON-encoded
      keychain item → iCloud sync →
      [`KeyLibrary.swift:32`](../Sources/SloopKit/Model/KeyLibrary.swift#L32) →
      [`LibSSH2Connection.swift:230`](../App/SloopSSH/LibSSH2Connection.swift#L230).
      The libssh2 call itself is correct.
- [ ] **The single test that closes all of the above**: generate an Ed25519 key
      *with* a passphrase, `sloop import-key` it on the Mac, let it sync, pick
      it on the iPad, connect. That exercises passphrase detection, the CLI
      prompt, the keychain round-trip, iCloud sync, `KeyLibrary.credential` and
      the libssh2 call in one run.
- [ ] **Negative case**: wrong passphrase typed into the host editor yields
      `KeyAuthFailure`'s "passphrase looks wrong" message, not a generic
      failure.

**How to test a key without fooling yourself.** `ssh -i <key> host` proves
nothing on its own: OpenSSH also offers your agent's keys and any
`IdentityFile` from `~/.ssh/config`, so a *different* key may be what
authenticates. This exact trap produced a false "Ed25519 works" reading on
2026-08-17, and is why the RSA result above is now in question. Always isolate:

```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/<key> user@host true   # only this key
ssh -v  -i ~/.ssh/<key> user@host true | grep 'Server accepts key'
```

The `Server accepts key:` line names the key that actually worked. Confirm it
is the one under test before recording a pass. The same reasoning applies to
the app: test against a host whose `sshd` has `PasswordAuthentication no`, or
you cannot tell key success from password success.

**Cloudflare Access**

- [ ] Token reused across a quit and relaunch — no browser sheet.
- [ ] "Use Mosh" is disabled and forced off, with the needs-UDP explanation.
- [ ] Token expiry re-presents the login sheet.
- [ ] A session revoked in Zero Trust yields a clear message, not a hang.

**SFTP / File Provider** — built, browsing verified 2026-08-18, the rest open

- [ ] The **write path**: upload, rename, delete.
- [ ] A **multi-gigabyte file**, to confirm streaming holds under a memory cap.
- [ ] **Access with the device locked** — see the open bug in §7, which
      predicts this fails for key-auth hosts.
- [ ] **Peak RSS during a large transfer.** The extension runs its own tsnet
      node — a ~23 MB Go runtime inside a memory-capped extension process.
      Jetsam here is exactly what a reviewer stumbles into. Fallback if it does
      not hold: drop the libtailscale targets and let tailnet hosts fail with a
      clear error.
- [ ] **Authorizing the extension's tailnet node** on a tailnet that requires
      device approval. No path exists today.
- [ ] **macOS Finder integration**, which needs the signed app in
      `/Applications`.

## 7. Security posture

Reviewed 2026-08-19. **No v1 action beyond the one bug below.**

- [x] **Keychain accessibility classes are correct.** Library keys are
      `kSecAttrAccessibleWhenUnlocked` + synchronizable
      ([`KeychainKeyStore.swift:97`](../App/SloopSSH/KeychainKeyStore.swift#L97)) —
      the strictest class compatible with iCloud sync. Per-host passwords, key
      passphrases and Access tokens are `AfterFirstUnlockThisDeviceOnly`
      ([`GenericPasswordStore.swift:110`](../App/SloopSSH/GenericPasswordStore.swift#L110)) —
      never synced, never off the device. The split is deliberate and right.
- [x] **Secure Enclave is not needed, and cannot serve the key library.** The
      SE holds P-256 keys only (no Ed25519, no RSA) and its keys are
      non-exportable and device-bound, so they cannot ride iCloud Keychain.
      That is mutually exclusive with "import once, use from every device."
      Viable later as a *separate* feature — device-bound P-256 keys, enrolled
      per device — via libssh2's `sign_callback` on
      `libssh2_userauth_publickey()`. Scoped honestly, it is not a hardening of
      the existing library. Deferred, see §8.
- [ ] **Open bug: the File Provider extension cannot read library keys on a
      locked device.** [`SFTPDomainService.swift:88`](../App/SloopFiles/SFTPDomainService.swift#L88)
      resolves keys through `KeychainKeyStore`, whose items are
      `WhenUnlocked`; the extension runs with no human present. Predicted
      symptom: key-auth hosts fail in Files.app while locked with
      `errSecInteractionNotAllowed`, while password-auth hosts on the same
      locked device work — their credentials are `AfterFirstUnlock`. Derived
      from the constants and the call site, **not yet run**. Two resolutions,
      and it is a real design call: accept it and say so in the UI, or split
      `NamedKey` so the material the extension needs sits one class weaker —
      which reopens exactly what
      [`KeychainKeyStore.swift:90-96`](../App/SloopSSH/KeychainKeyStore.swift#L90-L96)
      rejected on purpose.

Noted, not acted on: `NamedKey` carries the encrypted PEM and its passphrase in
a single keychain item, so the PEM's own encryption does no work at rest and
the protection is entirely the keychain's protection class. Standard practice
for SSH clients, and not worth changing — worth knowing.

## 8. Explicitly deferred past v1

Recorded so they are decisions rather than oversights.

- tvOS — blocked on SwiftTerm, see [`ROADMAP.md`](ROADMAP.md).
- Mac App Store (and therefore App Sandbox).
- The tip jar.
- Secure Enclave device-bound keys.
- Connection timeouts and keepalives — no `connect()` deadline and no
  `ServerAliveInterval` equivalent exists. [`ROADMAP.md`](ROADMAP.md) calls
  this the most-felt gap on its nice-to-have list, and it is: every mobile user
  hits it. Shipping without it is a choice; make it knowingly.
- Typed errors in `ConnectionState` — an auth failure, a dropped link and an
  expired Access session all render as the same grey text today.
- ProxyJump, agent forwarding, port forwarding, iCloud host sync, iPad
  multi-window, Apple Watch.
