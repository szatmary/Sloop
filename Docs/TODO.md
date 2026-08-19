# TODO

Open items that are not yet tracked in `ROADMAP.md` (which holds planned
features) or in `HANDOFF.md` (which holds the on-device checklist). Written
2026-08-18 because the review artifacts they came from live in gitignored
scratch directories that disappear with their worktrees — the substance is
recorded here rather than a pointer to something that will vanish.

---

## Blocking a real release

### Agent forwarding is unverified against a real host

Everything in PR #5 is unit-tested; nothing has spoken to a real sshd. That
distinction is not theoretical — the most serious bug found in review was that
`libssh2_channel_request_auth_agent` was issued *after* shell startup, and
OpenSSH only honours `auth-agent-req@openssh.com` while the channel is
`SSH_CHANNEL_LARVAL`. Every test passed and the feature never engaged.

The checklist is in `HANDOFF.md`. Start with `echo $SSH_AUTH_SOCK` on the
remote: if it is empty, nothing else on the list is worth running.

### The vendored libssh2 xcframework can be stale in a way that does not build

`Vendor/libssh2.xcframework`'s module map named only `libssh2.h`, which makes
`LIBSSH2_SFTP_ATTRIBUTES` invisible and the SFTP client uncompilable. The
repo's own `Scripts/deps/libssh2/files/module.modulemap` names both headers,
and its comment predicts this exact failure — the shipped artifact was simply
older than the script.

Anyone holding a pre-2026-08-18 xcframework needs to refresh it. Worth making
the build fail loudly on a stale module map rather than on a confusing missing
type, since the artifact is gitignored and every clone builds its own.

---

## Open review findings — SFTP File Provider (PR #4)

PR #6 fixes the three data-loss defects. These five are still open. File paths
are relative to the `worktree-sftp-file-provider` branch.

1. **Keychain accessibility mismatch.** `KeychainKeyStore.swift:97` stores keys
   `WhenUnlocked`; `GenericPasswordStore.swift:110` stores credentials
   `AfterFirstUnlockThisDeviceOnly`. A File Provider extension can be launched
   with the device locked, where the key read fails
   `errSecInteractionNotAllowed` — surfaced as a bare `NSError`, which
   `FileProviderError.swift:54-61` classifies as transient, producing a retry
   storm instead of a visible failure.
2. **A transient init failure pins the domain.**
   `FileProviderExtension.swift:27-46` caches init failure for the instance's
   life, so being launched once while locked disables that domain until the OS
   kills the process.
3. **`signalChange()` signals a working set the enumerator answers as empty.**
   `SFTPDomainService.swift:203` versus `FileProviderEnumerator.swift:36-39`
   and `:72-75`. Comments at `FileProviderExtension.swift:188` and `:255`
   assert an immediate re-enumeration that cannot happen.
4. **`enumerateChanges` ignores its anchor.**
   `FileProviderEnumerator.swift:70-99` diffs against its own snapshot;
   `currentSyncAnchor` returns one index-wide counter rather than a
   per-container one, and there is no `syncAnchorExpired` path, so a stale
   anchor yields "nothing changed" and items stay missing. `:82` also omits
   `parentIsWritable`, so capabilities differ between full and change
   enumerations (compare `:54`).
5. **The item index grows without bound.**
   `SFTPItemIndex.swift:250-258` keeps every path ever seen and re-encodes the
   whole file on every enumeration — in a process the OS memory-caps and kills
   without ceremony.

Smaller, same review: `FileProviderExtension.swift:280-289` swallows
`path(for:)` errors and reports delete success; `:317-322` and failed `read`
destinations are never unlinked; `LibSSH2SFTPClient.swift:128`'s 1024-byte name
buffer turns one long filename into a bogus `connectionLost` for the whole
listing.

---

## Test coverage gaps

### The File Provider layer has no tests at all

The `SloopTests` target sources only `Tests/SloopAppTests` and has no
dependency on the SloopFiles target, so `FileProviderExtension`,
`FileProviderEnumerator`, `FileProviderError`, `SFTPDomainService` and
`LibSSH2SFTPClient` are entirely untested — while `SFTPClient.swift:8-13`
claims they are "exercised against `InMemorySFTPClient`". Either wire the
target up or correct the comment; a doc comment asserting coverage that does
not exist is worse than silence.

### `App/SloopSSH` has no test bundle

Which is why PR #6's fixes — the redial, bounded teardown, close-error
propagation, the three rename branches, permission preservation — are compiled
but unasserted. They need a live SFTP server: ideally one OpenSSH and one
non-OpenSSH (for the v3 rename path), with a severable link.

---

## Deferred by decision, recorded so the reasoning is not lost

- **`ForwardedAgent.close()` can still leak** against a peer that opens a fresh
  channel on every close, through all `closeDrainRounds`. Deliberate bounded
  trade: the alternative lets the remote decide when teardown ends. Registering
  the AUTHAGENT callback only on forwarding sessions shrank the exposure.
- **Replies go unwritten if the remote half-closes before reading them.**
  Pre-existing, unchanged by the hardening work.
- **`HostListView` has six `.sheet` modifiers on one view.** The shared
  `PromptQueue` fixed the two that block an SSH thread; collisions between the
  rest (`$editing`, `$showingSettings`, …) are still possible and merely drop a
  dialog rather than hanging anything.
- **No `scenePhase` or `beginBackgroundTask` handling anywhere in the app**, and
  no timeout on `PromptQueue.request`. An SSH thread can sit on a semaphore
  waiting for a prompt the user cannot see because the app is backgrounded, and
  the prompt returns hours later looking live. Wants a deliberate answer, not a
  timeout bolted on: silently refusing after a delay is its own failure.
- **`AgentSigner` calls `free()` on `LIBSSH2_ALLOC` memory**, correct only
  because `session_init_ex(nil, nil, nil, …)` keeps the default allocator.
  Undocumented coupling in a file whose whole thesis is not trusting internals.
- **`AgentSigner.identities` uses `Dictionary(uniqueKeysWithValues:)`**, which
  traps on duplicate names. The UI cannot produce them; a hand-edited store
  file can.
- **`SSHHost.forwardsAgent` is used by nothing but tests and comments** now that
  forwarding gates on the resolved key list. Either use it or remove it.

---

## Housekeeping

- `AuthMethod.agent` is dead scaffolding with zero references — unrelated to
  agent forwarding despite the name. Removed on the merged `ssh-url-and-agent`
  work; confirm it is gone and delete it if not.
- The command-suggestions feature is specced and planned but not started:
  `Docs/superpowers/specs/2026-08-18-command-suggestions-design.md` and
  `Docs/superpowers/plans/2026-08-18-command-suggestions.md` (7 tasks).
