# Command suggestions: history built by reading the screen

_Approved 2026-08-18. Feature: stop making people type long commands on a phone
keyboard._

## Problem

Typing `docker compose -f prod.yml logs -f --tail=100 api` on a phone is
miserable. It is the same problem the compact keyboard attacks — the compact
keyboard makes each character cheaper; this makes most characters unnecessary.

Every competitor ships a saved-command library: Prompt calls them Clips, Blink
and Termius call them Snippets. All of them share one weakness — a curated list
goes stale, because curation is work nobody does. Sloop has none of this today.

The insight this design rests on: **the history is the snippet library.** Any
command you have run is a command you might run again, so there is nothing to
curate. `!1`, `!2` already exist as an idiom for exactly this.

## Decisions (from brainstorming)

- **The screen is the source.** Sloop reads terminal text via SwiftTerm's public
  `Terminal.getText(start:end:)`. Not keystrokes, not the remote shell's history
  file, not shell integration.
- **The model does the parsing.** No prompt-boundary parser, no alternate-screen
  gate, no heuristics for wrapped lines or `vim` screens. Screen text goes to the
  model and commands come back. A `vim` screen yields no commands because the
  model reads it as a `vim` screen, not because we detected the alt buffer.
- **On-device only.** Apple's Foundation Models framework. No API key, no cost,
  no network, and nothing leaves the phone. Rejected: a hosted model — terminal
  context is hostnames, internal infrastructure and command arguments, and
  "we send your terminal to a server" is a promise a shell client should not
  make. Also rejected on grounds of network: Sloop exists because mobile
  networks drop.
- **The model is required for this design; an alternative mode for older devices
  is deferred, not rejected.** An earlier draft carried a prompt-stripping
  extractor as a built-in fallback. Dropped from *this* spec deliberately —
  designing both at once meant a second, worse implementation of the feature's
  core competing for attention with the first. Where the model is unavailable
  the suggestion strip is simply absent, and something for those devices is
  separate work with its own spec.
- **The model may invent commands, not just recall them.** This is autocomplete,
  not a history picker: the useful suggestion is often one you have never run —
  the flag you can't remember, the incantation you'd otherwise go and look up.
  History is *context* that teaches the model your conventions (`docker compose`
  or `docker-compose`, your paths, your host naming), not the menu it must
  choose from.
- **Suggestions insert, never execute — and this is now the only safety
  boundary.** Tapping fills the input line; the user presses Return. Because the
  model can invent, it can invent something wrong or destructive, so nothing may
  auto-accept, auto-run, or run on a single tap. The user reads it and sends it,
  exactly as with shell tab-completion.
- **Invented suggestions look different from recalled ones.** A command drawn
  from history carries the authority of "I ran this before"; a generated one
  does not, and must not borrow it. The strip distinguishes the two visually so
  the user knows which claim is being made — a cheap safeguard against the real
  failure mode, which is not a bad suggestion but an unexamined one.

### Why reading the screen is also the safe choice

A password is never echoed, so it is **structurally absent from the screen** —
not filtered, not heuristically suppressed. It was never there to capture. This
is why the source matters more than any safeguard: capturing keystrokes would
have required detecting echo suppression, which a terminal emulator cannot do
reliably (echo is a remote termios setting the client is never told about).
Reading the screen makes the whole problem disappear.

The residual case is a secret echoed on the command line (`mysql -pSECRET`,
`curl -H "Authorization: Bearer …"`). That lands on screen, so it lands in
history — exactly as it already lands in the user's `~/.zsh_history`. Sloop is
no worse than the host, and honours the same escape hatch: **a command whose
line begins with a space is not recorded**, matching the `HISTCONTROL=ignorespace`
convention people already use.

## Design

### 1. Capture — cheap, synchronous, on Return

`TerminalController.send(source:data:)` already sees every byte the user sends.
When it sees `0x0d`, it snapshots the screen region since the previous snapshot
via `Terminal.getText` and appends it to a pending queue.

Snapshotting is a string copy — it must not block input, and it does not call
the model. Extraction happens off the input path, so model latency never shows
up as keyboard lag.

### 2. Extraction — one implementation

`CommandExtractor` (App layer) wraps Foundation Models: screen text in, a list
of commands out. It uses a `@Generable` result type so the model returns a typed
list rather than free text to parse.

Guarded at two levels — `#available` for the OS, and a runtime
`SystemLanguageModel.default.availability` check, because Apple Intelligence can
be switched off, still downloading, or unsupported on the device. When the check
fails the app captures nothing and shows no strip; nothing else in the app
changes behaviour.

### 3. Storage — per host, on device

`CommandHistory` in SloopKit: an ordered, de-duplicated list of commands per
`SSHHost`, each with a last-used timestamp and a use count. Pure and
unit-testable; no UIKit, no model, no persistence in the type itself.

Persistence is a JSON file per host under Application Support with
`FileProtectionType.complete`, so it is encrypted at rest whenever the device is
locked. **Not** the Keychain: the Keychain is for secrets, and this is a growing,
frequently-written list — using it would be both a poor fit and a claim that the
contents are secret, which they are not. Not `UserDefaults`: plaintext, backed
up, and inspectable.

Requirements on the store:

- **Purge** — clear one host's history or all of it, from Terminal Settings.
- **Cap** — a bounded number of commands per host (a few hundred), evicting by
  frecency, so the file cannot grow without limit on a long-lived host.
- **Screen text is never persisted.** Only extracted commands are stored. The
  snapshots in §1 live in memory until extracted, then are discarded. This is
  the difference between storing "what I ran" and storing "everything my server
  ever printed at me", and it is the whole reason the durable artifact stays
  small and explicable.

### 4. Suggestion

The model is given three things and asked for the next command: what is on the
screen now, what the user has typed on the current line so far, and a slice of
`CommandHistory` for this host.

History's job here is **context, not candidates**. It is what teaches the model
that this user writes `docker compose` rather than `docker-compose`, that
deploys go through `make deploy` and not a raw `kubectl`, what the hosts and
paths are called. A suggestion may come straight out of history, may be a
variation on something in it, or may be novel — the last case is often the most
useful one, because the command you cannot remember is the command worth
suggesting.

`CommandHistory` still orders by frecency (recency × frequency) and filters by
prefix as the user types, which decides *which* slice of history is worth
sending as context and keeps the prompt small.

Each returned suggestion is tagged as recalled (matches a stored command) or
invented, which is what drives the visual distinction in §5. That tag is
computed by comparing against the store, not asserted by the model — the model
is not asked to be honest about its own novelty.

### 5. UI — a strip above the keyboard, numbered

A horizontal strip of suggestions sits with the keyboard accessory. Tapping one
inserts it at the cursor; it does not send. Entries are numbered so the `!1`,
`!2` idiom works by eye and by tap.

Recalled and invented suggestions are visually distinct (§Decisions). A recalled
command is something the user has run on this host before and can trust on that
basis; an invented one is the model's guess and deserves a read before Return.
Presenting them identically would launder the second into the first.

This composes with the compact keyboard rather than competing with it: the
compact keyboard makes each character cheaper, and suggestions make most of the
characters unnecessary.

### 6. Testing

The durable, order-dependent logic is pure and lives in SloopKit, so it is
reachable by `swift test` on the existing target:

- `CommandHistory` — de-duplication, frecency ordering, the cap and its eviction
  order, purge.
- The leading-space rule — a command entered with a leading space never reaches
  the store.
- Prefix filtering, given a fixed store.

Extraction and model ranking are verified on device: they need Apple
Intelligence and real hardware, and their output is not deterministic. What is
testable about them is the availability gate and that a failed extraction leaves
the store unchanged — not the model's answers.

## Implementation notes

**Confirm the Foundation Models API surface against current documentation before
writing against it.** The shape assumed here — `SystemLanguageModel.default`,
`availability`, `LanguageModelSession`, `@Generable` — should be re-checked
rather than trusted from this document; the framework is young and this spec's
value is the design, not the API spelling.

**Decided: 26 or nothing.** Foundation Models requires iOS 26, and the feature
is gated on it — no second implementation for older systems, no degraded mode.
Sloop's own floor stays at iOS 17 (`project.yml`; SloopKit `.v17`) and the
feature is `#available`-gated inside it, because raising the app's minimum
would drop users from *every* feature to deliver this one.

Worth knowing before building: **the OS version is not the binding constraint —
the silicon is.** Apple Intelligence requires A17 Pro / M1 or later. Every iPad
currently shipping can run iPadOS 26, so a 26 floor excludes no new device; but
the base iPad (A16) does not meet the Apple Intelligence bar at all, so the
cheapest iPad Apple sells today gets no suggestion strip regardless of its OS.
Whatever the strip's absence looks like, it has to look deliberate on
current hardware, not broken. (Lineup facts as of 2026-08 — re-check before
building.)

Suggested build order:

1. `CommandHistory`, capture on Return, and the suggestion strip ranked by
   frecency. Nothing here needs the model, and it makes the store and UI real
   before anything depends on them.
2. `CommandExtractor` behind the availability gate — the model turns captured
   screens into commands.
3. Model re-ranking against the current screen.

## Accepted limitations

- **The feature requires iOS 26 with Apple Intelligence enabled on supported
  hardware.** Elsewhere the strip does not appear. An alternative mode for older
  devices is planned as separate work; it is out of scope here so that this
  design is not shaped around a second, weaker one.
- **It cannot be dogfooded on the author's iPad.** The paired device is an iPad
  (9th generation) — A13, below the Apple Intelligence bar — so the only
  hardware on hand that can run this is an iPhone 15 Pro Max (A17 Pro). The
  device where phone-typing hurts most is the one that cannot run the fix, which
  makes the deferred alternative mode more than a nicety. Any judgement about
  how the strip *feels* on a tablet is untestable until there is M-series or
  A17 Pro iPad hardware to hand.
- **Extraction quality is the model's.** A mis-read screen produces a junk entry
  in a list the user can purge — not a wrong command executed.
- **The model can suggest a wrong or destructive command.** That is the cost of
  letting it invent rather than only recall, and it is accepted deliberately —
  the suggestion worth having is usually the one you could not have recalled.
  The mitigations are that nothing runs without the user pressing Return, and
  that invented suggestions are marked as such. The residual risk is a plausible
  suggestion accepted without reading, which is the same risk shell
  tab-completion and every code-completion tool already carries.
- **Secrets echoed on the command line are recorded**, exactly as the remote
  shell records them. Mitigated by the leading-space rule and by purge, not
  eliminated.
- **Suggestions are per host.** No cross-host sharing and no iCloud sync in this
  design. Syncing history the way the key library syncs keys is plausible later,
  but it converts an on-device artifact into a synced one, which is a separate
  privacy decision and should be made deliberately rather than inherited.
