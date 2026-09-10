# Apple Watch — what's actually worth doing

Short version: **not a terminal.** A full interactive PTY on a 1.5" screen with
no keyboard, where watchOS suspends your process aggressively, is a bad
experience and long-lived SSH/Mosh sessions can't survive the background limits.
Don't port the terminal.

What the watch is genuinely good for is the **ops glance**: tap a host, tap a
saved command, read the output. From your wrist: `uptime`, `df -h`, `docker ps`,
"restart nginx", "is the deploy up?". That's a real, differentiated use case.

## The shape

- **Command runner, not a shell.** Use an SSH **exec** channel
  (`libssh2_channel_exec`), not an interactive PTY: connect → run one command →
  capture stdout/stderr + exit status → disconnect. This maps perfectly onto
  watchOS's short-execution model, unlike a persistent shell.
- **Let the phone do the SSH.** Prefer **WatchConnectivity (WCSession)**: the
  watch sends "run command X on host Y"; the paired iPhone holds the credentials
  (keychain) and the known-hosts DB, runs the SSH exec, and returns the output.
  This avoids duplicating secrets onto the watch and sidesteps watch
  networking/background limits. A standalone LTE watch *could* SSH directly, but
  with the background caveats above — make it the fallback, not the default.
- **Input** is realistic here because commands are short and mostly *saved*: a
  curated per-host command list, plus Scribble/dictation/the tiny QWERTY for the
  rare ad-hoc command. No need to type a full shell.
- **Complications**: a periodic health check (up/down, load, disk) surfaced on
  the watch face via background refresh (small budget — think minutes, not
  seconds). Tapping it opens the relevant host.
- **Notifications → quick action**: a server alert push with a canned command as
  the response.

## How it reuses Sloop

SloopKit is Foundation-only, so it already compiles for watchOS. Shared as-is:
`Host`, `HostStore`, `CredentialStore`, `KnownHostsStore`.

The one new piece — and it's **useful on iOS/Mac too**, so it's worth building
before any watch work — is a non-interactive **`CommandRunner`** (SSH exec:
run a command, return `{stdout, stderr, exitStatus}`). On phone/Mac it powers
saved snippets and one-shot commands; on the watch it's the whole app. The watch
target then adds only a WCSession bridge and a small SwiftUI command palette
(no SwiftTerm — it doesn't support watchOS and isn't needed).

## Verdict

Park it until SSH (M1) is real. Then the cheapest path to a compelling watch app
is: build `CommandRunner` on the exec channel (wanted anyway), add a WCSession
request/response bridge, and a SwiftUI list of hosts → saved commands → output.
tvOS-style "big remote terminal" it is not; "kubectl/systemctl from your wrist"
it very much is.
