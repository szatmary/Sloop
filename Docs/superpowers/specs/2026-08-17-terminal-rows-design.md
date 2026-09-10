# More usable terminal rows: dismissible keyboard + a compact keyboard

_Approved 2026-08-17. Feature: get more visible rows out of the terminal on
iPhone and iPad, where the software keyboard is the single largest consumer of
screen space._

## Problem

A terminal's whole job is showing text, and on iOS most of the screen shows a
keyboard instead. Two specific faults:

1. **The keyboard cannot be dismissed at all.** There is no `resignFirstResponder`
   path anywhere in the app. Once SwiftTerm's `TerminalView` takes first
   responder, the keyboard is up for the rest of the session — including the
   large majority of the time spent reading output rather than typing.
2. **Apple's keyboard is sized for prose, not for a terminal.** This is worst on
   iPad in landscape, where it is sized to touch-type across a 1194pt-wide
   screen: roughly 353pt of height spent on keys about 119pt wide. A finger is
   about 44pt. The excess is entirely vertical, and vertical is the axis a
   terminal cares about.

A third, smaller fault compounds both: `KeyboardAccessoryBar` is a sibling in
`TerminalPane`'s `VStack` rather than an `inputAccessoryView`, so it reserves
44pt of layout height whether or not the keyboard is visible.

## Row budget

Measured against the current layout, after the chrome reclaimed in
`011432d` (navigation bar, status bar, and iOS tab strip removed).

Line height is assumed to be **15.5pt** for the default 13pt monospaced font.
**This figure is an estimate and has not been measured on device.** Every row
count below scales with it; see "First task" under Implementation notes.

iPhone 15 Pro portrait (852pt tall, 59pt Dynamic Island inset retained):

| State | Chrome | Terminal | Rows |
| --- | --- | --- | --- |
| Today | 59 island + 44 bar + 216 keyboard | 533pt | ~34 |
| Keyboard dismissed, bar collapsed | 59 island | 793pt | ~51 |
| Compact keyboard (~215pt, bar folded in) | 59 + 215 | 578pt | ~37 |

iPad Pro 11" landscape (834pt tall; the top inset is already reclaimed on iPad):

| State | Chrome | Terminal | Rows |
| --- | --- | --- | --- |
| Today | 44 bar + ~353 keyboard | 437pt | ~28 |
| Keyboard dismissed, bar collapsed | none | 834pt | ~53 |
| Compact keyboard (~196pt, bar folded in) | 196pt | 638pt | ~41 |

Dismissal is the larger win on both devices; the compact keyboard is the larger
win *while typing*, and dramatically more so on iPad landscape (~13 rows) than
on iPhone (~3). Both are worth building, and dismissal is the cheaper half.

## Decisions (from brainstorming)

- **Both halves ship**: dismissal (A) and a compact keyboard (B).
- **Symbol access is adaptive.** iPad has width to spare, so symbols get a
  dedicated always-visible row. iPhone does not, so those symbols ride on a
  drag-up gesture on the digit row. One key model, two resolutions.
- **The standard/compact choice is a global setting** in Terminal Settings, next
  to font size, theme, and cursor — it is a preference about the user's hands,
  not about a host.
- **No Blink Shell source is copied.** Blink's SmarterKeys is an accessory bar
  of the same 44pt height as Sloop's, so porting it buys zero rows; its layout
  engine is coupled to `SmarterTermInput` and a hidden `WKWebView` that Sloop
  has no equivalent of. The *idea* of trait-resolved layouts and two-value keys
  is adopted; the code is not. Sloop therefore takes on no additional §7
  attribution obligations and `Docs/LICENSING.md` stays accurate as written.
- **SwiftTerm's own `KeyboardView` is a reference, not a base.** It proves
  `inputView` works on `TerminalView`, but it has no letter keys, so it cannot
  serve as a keyboard.
- **No live "switch to system keyboard" key.** Rejected in favour of the plain
  global setting. See "Accepted limitations".

## Design

### 1. SloopKit: the key model (pure, unit-tested)

New `Sources/SloopKit/Terminal/KeyCap.swift`:

```swift
public struct KeyCap: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case character(Character)     // encodes via KeyEncoder.bytes(for:modifiers:)
        case key(TerminalKey)         // encodes via KeyEncoder.bytes(for:modifiers:applicationCursor:)
        case modifier(KeyModifiers)   // arms a sticky modifier; emits nothing
        case command(Command)         // app-level action; emits nothing
    }

    public enum Command: Equatable, Sendable {
        case dismissKeyboard
        case closeTab
    }

    public enum Width: Equatable, Sendable {
        case unit           // one grid slot
        case wide(Double)   // a multiple of a slot, e.g. .wide(2) for ⏎
        case flexible       // absorbs the remaining width, e.g. the space bar
    }

    public let primary: Value
    /// Reached by dragging up past a threshold. Nil on layouts that give
    /// symbols their own row.
    public let secondary: Value?
    public let width: Width
    /// Whether press-and-hold repeats. True for backspace and arrows.
    public let repeats: Bool
}
```

New `Sources/SloopKit/Terminal/KeyboardLayout.swift`:

```swift
public struct KeyboardLayout: Equatable, Sendable {
    public let rows: [[KeyCap]]
    /// Height of one key row, in points. Varies by context — see below.
    public let rowHeight: Double

    public struct Context: Equatable, Sendable {
        public enum Idiom: Sendable { case phone, pad }
        public enum Orientation: Sendable { case portrait, landscape }
        public let idiom: Idiom
        public let orientation: Orientation
        public let width: Double
    }

    public static func resolve(for context: Context) -> KeyboardLayout
}
```

`resolve` is the entire adaptive decision, expressed as one pure function over
value types. It holds the layout tables and the rule that distinguishes them:

- **iPad (either orientation)**: five rows — a dedicated symbol row
  (`~ ` | \ / [ ] { } < > - _ = + ; : ' "`), a digit row, and three letter rows
  carrying the modifiers, arrows, return, space, backspace, and dismiss.
  `secondary` is nil throughout; nothing is hidden behind a gesture.
- **iPhone (either orientation)**: four rows — the symbol row is dropped and its
  eighteen symbols become the `secondary` values of the digit row and the
  punctuation keys. Fewer rows, same reachable character set.

  The exact symbol-to-key assignment is left to implementation, constrained by
  the character-set parity test below: any assignment that keeps every iPad-
  reachable character reachable on iPhone is acceptable. Pair by keyboard
  convention where one exists (`1`→`!`, `-`→`_`, `[`→`{`), since a learnable
  mapping is worth more than an optimal one.

`resolve` also returns a row height, which varies by context rather than being
fixed: iPhone portrait keys are narrow (per `CompactKeyboardView`'s slot
algorithm — padding 4, spacing 3 — a 393pt screen renders the 12-unit-cap
digit/tab/control rows at ~29.3pt, and the modifier-bearing bottom row at
~24.9pt, both under Apple's own ~32pt key width) and want height to compensate,
while iPad landscape keys are wide and can afford to be short.
**iPhone landscape is the hard case** — the screen is only ~393pt tall, so a
four-row keyboard must use short rows or it consumes more than half the display.
Treat iPhone landscape as the layout most likely to need its own row height, and
confirm it on device before assuming the portrait values transfer.

Both resolutions must satisfy the invariants tested below, which is what keeps
the two tables honest as they are edited.

### 2. Encoding: no second path

`KeyCap.Value` deliberately mirrors the two `KeyEncoder.bytes(for:)` overloads
that already exist. Rendering code converts a cap to bytes by calling
`KeyEncoder`, passing the armed modifiers and the live `applicationCursor`
state, exactly as `KeyboardAccessoryBar` does today.

This matters because `KeyEncoder` is where the non-obvious correctness lives —
xterm's Ctrl+digit mapping, `key & 0x1F` with upper-casing, DECCKM SS3-vs-CSI
cursor keys, and the `1;<n>` modifier parameter. A keyboard that grew its own
encoding would duplicate all of it and drift. `KeyCap` carries *what* a key is;
`KeyEncoder` remains the only thing that decides what it emits.

### 3. App: rendering

New directory `App/Sloop/Views/Keyboard/`. `KeyboardAccessoryBar.swift` moves
into it; the rest are new.

- **`CompactKeyboardView: UIView`** — assigned to `terminalView.inputView`, the
  same hook SwiftTerm's `KeyboardView` uses. Builds its subviews from a resolved
  `KeyboardLayout` and reports its own `intrinsicContentSize` height from the row
  count, rather than accepting the system keyboard's height. Rebuilds on
  `bounds` change (rotation, iPad split view).
- **`KeyCapView: UIControl`** — one key. Three interactions:
  - tap → `primary`
  - drag up past ~20pt → `secondary` (no-op when nil)
  - press and hold → repeat after ~0.4s at ~0.07s intervals, for caps with
    `repeats == true`
  Modifier caps render armed state from the same `TerminalController.armedModifiers`
  the bar already binds to, so sticky modifiers behave identically in both modes.
- **`FloatingKeyPill: View`** — the collapsed bar shown when the keyboard is
  down: restore-keyboard, pgup, pgdn. An overlay on the terminal, not a `VStack`
  sibling, so it costs zero layout rows.

### 4. Dismissal

`TerminalController` gains:

```swift
func dismissKeyboard()                       // terminalView.resignFirstResponder()
@Published private(set) var keyboardVisible: Bool
```

`keyboardVisible` is driven by `UIResponder.keyboardWillShowNotification` and
`keyboardWillHideNotification` rather than by tracking calls, so a keyboard
hidden by the system (not by us) is also observed.

Restoring needs no new code: SwiftTerm's `singleTap` handler already calls
`becomeFirstResponder()`, so tapping the terminal brings the keyboard back.

`TerminalPane` shows the full bar when `keyboardVisible`, and `FloatingKeyPill`
otherwise — but **only when no hardware keyboard is attached**
(`GCKeyboard.coalesced == nil`, from GameController). With a hardware keyboard,
no show/hide notification fires and the bar must stay visible; that is the
behaviour `TerminalController`'s existing `inputAccessoryView = nil` comment
deliberately protects, and collapsing the bar there would regress it.

Toggling the keyboard changes the terminal's height, so `sizeChanged` fires and
the remote receives a `SIGWINCH` on every hide and show. This is accepted:
full-screen apps reflow, which is what every mobile terminal does and what tmux
expects. The alternative — holding the grid fixed and merely scrolling — gains
no rows and so does not serve the goal.

### 5. The setting

`TerminalAppearance` gains:

```swift
public enum KeyboardStyle: String, Codable, CaseIterable, Sendable {
    case standard   // the system keyboard, plus today's smart-keys bar
    case compact    // CompactKeyboardView, bar folded in
}
public var keyboard: KeyboardStyle
```

Decoded through `decodeIfPresent(...) ?? .standard`, matching how `theme` and
`cursor` already tolerate older stored values. A "Keyboard" section in
`TerminalSettingsView` picks between them.

`TerminalController.apply(_:)` installs or clears `terminalView.inputView`
according to the style, in a branch kept separate from the font/palette/cursor
work so the two concerns stay legible.

`TerminalAppearance` currently documents itself as the *look* of the terminal,
and a keyboard style is input, not look. Adding it here anyway is a deliberate
trade: a parallel `InputPreferences` model and store for a single enum is more
structure than the problem earns today. If input settings grow — key repeat
rate, Caps Lock remapping, hardware chords — split them out then, and widen this
type's doc comment at that point rather than pre-building the seam.

### 6. Testing

SloopKit tests (`Tests/SloopKitTests/KeyboardLayoutTests.swift`), pure and
runnable in CI without a device:

- `resolve` returns 5 rows for both iPad contexts and 4 for both iPhone contexts.
- iPad caps all have `secondary == nil`; iPhone caps place every symbol that the
  iPad symbol row carries somewhere reachable.
- **Character-set parity**: the set of characters reachable on iPhone (primary ∪
  secondary) equals the set reachable on iPad. This is the invariant that stops
  the two tables drifting as they are edited.
- Every printable ASCII character a shell needs is reachable in both.
- No duplicate key within a row; `Width.flexible` appears at most once per row.
- `KeyCap.Value` → bytes agrees with `KeyEncoder` for a representative sample,
  including a Ctrl+digit case and an application-cursor arrow.

View behaviour (drag threshold, repeat timing, rotation rebuild) is verified on
device, which is the M4 open risk the roadmap already tracks.

## Implementation notes

**First task, before any layout table is written**: log the real cell height and
the real system-keyboard frame on an iPad in landscape and an iPhone in
portrait. Everything above rests on the 15.5pt estimate, and the target heights
(196pt / 215pt) are only sensible if a usable key size fits in them. If the
compact keyboard cannot get meaningfully under ~250pt at a comfortable key size,
the case for part B weakens and is worth re-deciding before the tables are
built. Dismissal (part A) is unaffected by this measurement and can proceed
regardless.

Suggested order: measure → part A (dismissal, pill, hardware-keyboard guard) →
`KeyCap`/`KeyboardLayout` + tests → `CompactKeyboardView`/`KeyCapView` →
the setting.

## Accepted limitations

- **Dictation, emoji, and non-US layouts are unavailable in compact mode**, and
  the only way back is the Settings toggle. This is a real cost, accepted for
  now in exchange for a simpler surface. A long-press on the dismiss key mapping
  to "system keyboard for this session" would relieve it cheaply if it proves
  annoying in use.
- **The compact keyboard is US QWERTY only.** Users on other layouts should stay
  on `.standard`, which is the default.
- **Autocorrect, predictive text, and the QuickType bar are already off** —
  SwiftTerm sets `autocorrectionType`/`spellCheckingType` to `.no` — so there is
  no QuickType row to reclaim and no behaviour change there.
