# Terminal rows — handoff

Companion to `Docs/superpowers/specs/2026-08-17-terminal-rows-design.md` and
`Docs/superpowers/plans/2026-08-17-terminal-rows.md`. Branch: `terminal-rows`,
26 commits from `483e600`, 137 tests (92 at branch start).

**Nothing in this feature has ever run on hardware.** Every row count in the
spec rests on an unmeasured 15.5pt line-height estimate, and the compact
keyboard's four row heights are placeholders back-solved from it. That was a
deliberate, recorded decision — the plan's first task was to measure, and no
device was available — but it means the central claim is a hypothesis.

## What shipped

- **The keyboard can be dismissed.** Previously there was no
  `resignFirstResponder` path anywhere in the app: once the terminal took first
  responder the keyboard was up for the rest of the session.
- **The smart-keys bar stops reserving 44pt when the keyboard is down**,
  collapsing to a floating pill that overlays the terminal at zero layout cost.
- **An optional compact keyboard** replaces Apple's via `inputView`, chosen in
  Terminal Settings, defaulting to Standard. iPad gets a dedicated symbol row;
  iPhone puts those symbols on drag-up secondaries. The bar folds into it.
- **`KeyEncoder` remains the only thing that decides bytes.** `KeyCap` says what
  a key *is*; encoding was never duplicated.
- **No Blink Shell source was copied**, so `Docs/LICENSING.md`'s "no third-party
  GPL source is pasted in" stays true. Only the *idea* of trait-resolved layouts
  and two-value keys was adopted.

## Device checklist, in priority order

1. **Does the compact keyboard take its height at all?** It was found to be
   laid out at zero height (`frame: .zero` + `allowsSelfSizing` with
   `translatesAutoresizingMaskIntoConstraints` left `true`). Fixed in code,
   never run. The failure mode is silent — a blank keyboard-tinted bar, not a
   crash. Check this first; nothing else matters if it fails.
2. **Does the DEBUG `assertionFailure` on a zero-width layout pass fire?** If it
   does during normal use, downgrade it to a one-shot log — do *not* restore a
   silent `return`.
3. **Measure.** Log `frame.height / newRows` from `TerminalController.sizeChanged`
   and the keyboard frame from `keyboardWillShow`, on iPhone portrait, iPhone
   landscape, iPad landscape, iPad portrait. Replace the four placeholder
   `rowHeight` values in `KeyboardLayout.swift`. **This carries the plan's
   original decision gate**: if a compact keyboard cannot get meaningfully under
   ~250pt at a usable key size, part B's case weakens and is worth re-deciding.
4. **Do `keyboardWillShow`/`Hide` fire for a custom `inputView`?** The whole
   chrome state machine assumes they do. If not, compact mode leaves
   `keyboardVisible` stuck true and the pill never returns. Tap-to-restore
   backstops it, but the bar/pill logic would be wrong.
5. **Key repeat while held**, and **the key click** (needs the
   `UIInputViewAudioFeedback` conformance to work; its absence is silent).
6. **Drag-up secondaries at a natural drag speed.** The original threshold
   measured per-callback delta rather than cumulative distance, so only fast
   flicks worked; now cumulative with a latch. On iPhone, 21 characters are
   reachable *only* this way.
7. **Backspace drag-up does not delete an extra character.** A touch-down emit
   was firing the primary alongside the secondary — backspace *and*
   forward-delete. Fixed, unverified. One residual case remains: hold past
   ~0.4s so auto-repeat starts, *then* drag slowly — primaries can still fire
   alongside the secondary.
8. **iPad portrait symbol-row labels overflow.** That row is 31.5pt (27.8pt on
   an iPad mini) but "home"/"pgup"/"pgdn" need ~40.8pt at 17pt SF Mono, and the
   label has no width constraint and does not clip. Deliberately parked: the
   right fix (smaller font, clipping, or shorter labels) is a judgement best
   made looking at a real screen.
9. **Tap targets.** iPhone portrait's bottom row renders at ~23pt against
   Apple's own ~32pt keys. The floating pill's buttons are smaller still and
   float over live output, where a mis-tap sends `pgdn` while you are reading.
10. **iPhone landscape** — a four-row keyboard at 168pt on a ~393pt-tall screen.
    Flagged from the start as the layout most likely not to work.

## Decisions that are yours, not mine

- **VoiceOver and Switch Control cannot switch between open tabs on iOS.**
  `TabStrip` is `#if !os(iOS)`, tab switching is edge-swipe only, and the new
  escape action always exits to the host list. Introduced by `011432d`
  (removing the iOS tab strip), so it predates this work. The fix is a design
  question — an accessible tab switcher, or an escape action that cycles before
  dismissing — so it was not answered blind.
- **CI has no Linux job**, only macOS runners. "SloopKit must compile for Linux"
  was treated as a binding constraint here and shaped real decisions (a
  `KeyFrame` struct instead of `CGRect`), but it has never once been verified.
  Either add `runs-on: ubuntu-latest` + `swift test`, or drop the claim.
- **`Package.swift` declares only the SloopKit target**, so `swift test` covers
  zero app-layer code, and the only app-level XCTest target builds macOS. Every
  defect found late on this branch was in app-layer code that CI cannot see.
  The response here was to *extract* logic into SloopKit — `KeyboardLayout.frames()`
  and `KeyboardChrome.resolve()` both live there for exactly this reason — but
  an iOS test target would be worth more.
- **Is `.accessibilityAction(.escape)` redundant?** `UINavigationController`
  handles the VoiceOver escape gesture by default and `NavigationStack` is
  backed by one, but this screen hides its nav bar and adds a
  `simultaneousGesture`. Harmless either way; worth knowing which.

## Known-accepted limitations

- Compact mode is **US QWERTY only**, with no dictation and no emoji — those
  live on the system keyboard. Standard remains the default.
- **Shift is one-shot sticky with no caps lock**, so a run of capitals costs one
  ⇧ tap per letter.
- The compact keyboard's keys are smaller than Apple's on iPhone. That is the
  trade the feature exists to make, but it has a floor and this has not been
  tested against a real thumb.
