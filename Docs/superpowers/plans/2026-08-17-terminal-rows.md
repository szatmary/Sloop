# More Usable Terminal Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover terminal rows on iOS by making the keyboard dismissible and by
offering a compact, terminal-shaped keyboard in place of Apple's.

**Architecture:** A pure key model (`KeyCap`, `KeyboardLayout`) lives in SloopKit
and is unit-tested without a device; UIKit views in `App/Sloop/Views/Keyboard/`
render it. Every key encodes through the existing `KeyEncoder` — there is no
second encoding path. The keyboard is installed via `terminalView.inputView`,
the same hook SwiftTerm's own `KeyboardView` uses.

**Tech Stack:** Swift 5.9+, SwiftUI + UIKit, SwiftTerm, XCTest, XcodeGen.

**Spec:** `Docs/superpowers/specs/2026-08-17-terminal-rows-design.md`

## Global Constraints

- **License header** — every new `.swift` file under `Sources/`, `App/`, and
  `Tests/` starts with these exact two lines (GPL-3.0 §7 requirement, see
  `Docs/LICENSING.md`):
  ```swift
  // Sloop — Copyright (C) 2026 Matthew Szatmary
  // GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md
  ```
- **No Blink Shell source may be copied into this repo.** The trait-resolved
  layout idea is adopted; the code is not. Copying it would add §7 attribution
  obligations and make `Docs/LICENSING.md`'s "no third-party GPL source is
  pasted in" false.
- **No second encoding path.** `KeyCap` says *what* a key is; `KeyEncoder`
  remains the only thing that decides what bytes it emits.
- **SloopKit stays platform-agnostic** — no UIKit/SwiftUI/SwiftTerm imports in
  `Sources/SloopKit`. It must keep compiling for Linux and tvOS.
- **No project.yml changes needed** — `App/Sloop` is globbed by path, so new
  subdirectories are picked up automatically. Same for SwiftPM under
  `Sources/SloopKit`.
- **Test command** for all SloopKit work: `swift test` from the repo root.
  Filter with `swift test --filter <TestClassName>`.
- **iOS-only UI.** All view code added by this plan is inside `#if os(iOS)`.
  macOS has a hardware keyboard and needs none of it.

---

### Task 1: Measure the real numbers

Everything downstream rests on a 15.5pt line-height estimate that has never been
verified. This task replaces the estimate with measurements and writes them into
the spec. **It produces no shipping code** — the instrumentation is removed at
the end.

**Files:**
- Modify: `App/Sloop/Views/TerminalController.swift` (temporary logging)
- Modify: `Docs/superpowers/specs/2026-08-17-terminal-rows-design.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a "Measurements" section in the spec giving, per device and
  orientation, the real `lineHeight` (pt), system keyboard height (pt), and
  terminal rows with the keyboard up and down. Task 5 reads these to pick row
  heights.

- [ ] **Step 1: Add temporary logging to the size-change delegate**

`sizeChanged` already receives the authoritative row count. `cellDimension` is
**internal** to SwiftTerm and cannot be read from here, so derive line height
from the view's height instead.

In `TerminalController.sizeChanged(source:newCols:newRows:)`, before the
existing `transport.resize` call:

```swift
#if os(iOS)
// TEMPORARY (Task 1 measurement) — remove before Task 2.
let lineHeight = newRows > 0 ? source.frame.height / CGFloat(newRows) : 0
print("[measure] rows=\(newRows) cols=\(newCols) "
    + "viewH=\(source.frame.height) lineHeight=\(lineHeight)")
#endif
```

- [ ] **Step 2: Add temporary keyboard-frame logging**

At the end of `init`, inside the existing `#if os(iOS)` block:

```swift
// TEMPORARY (Task 1 measurement) — remove before Task 2.
NotificationCenter.default.addObserver(
    forName: UIResponder.keyboardWillShowNotification,
    object: nil, queue: .main
) { note in
    let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    print("[measure] keyboardHeight=\(frame?.height ?? -1)")
}
```

- [ ] **Step 3: Run on device and collect numbers**

Build and run on hardware — the Simulator's keyboard metrics are not reliable
for this, and "Connect Hardware Keyboard" suppresses the software keyboard
entirely. For **each** of these four configurations, connect to any host, then
show and hide the keyboard, recording both log lines:

1. iPhone portrait
2. iPhone landscape
3. iPad landscape (the motivating case)
4. iPad portrait

- [ ] **Step 4: Write the measurements into the spec**

Add a `## Measurements` section immediately after `## Row budget`, with a table
of the four configurations: line height, keyboard height, rows with keyboard up,
rows with keyboard down. Then edit the `## Row budget` tables to use the real
line height, and change the sentence "This figure is an estimate and has not
been measured on device" to state the measured value and the date.

- [ ] **Step 5: Decision gate — confirm part B is still worth building**

The spec's own condition: if a compact keyboard cannot get meaningfully under
~250pt at a comfortable key size (≥40pt rows on iPad, ≥44pt on iPhone), part B's
case weakens and should be re-decided before any layout table is written.

Compute for iPad landscape: `5 rows × chosen row height + padding`. Compare the
resulting row count against the measured keyboard-up baseline. **If the gain is
under 6 rows, stop and report to the user rather than continuing to Task 4.**
Tasks 2–3 (dismissal) are unaffected either way and should proceed regardless.

- [ ] **Step 6: Remove the instrumentation**

Delete both temporary blocks added in Steps 1 and 2. Verify none remain:

```bash
grep -rn "TEMPORARY (Task 1" App/ && echo "STILL PRESENT — remove" || echo "clean"
```

- [ ] **Step 7: Commit**

```bash
git add Docs/superpowers/specs/2026-08-17-terminal-rows-design.md App/Sloop/Views/TerminalController.swift
git commit -m "Spec: replace the estimated line height with device measurements"
```

---

### Task 2: Make the keyboard dismissible

**Files:**
- Modify: `App/Sloop/Views/TerminalController.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `TerminalController.dismissKeyboard()`,
  `TerminalController.keyboardVisible: Bool` (`@Published private(set)`), and
  `TerminalController.hardwareKeyboardAttached: Bool`. Task 3 consumes all three.

This task has no automated test — it is UIKit responder behaviour with no seam
that a unit test can reach without a running app. It is verified on device in
Task 3, whose UI makes the behaviour observable. Keep it small for that reason.

- [ ] **Step 1: Add the published visibility state**

Add to `TerminalController`, next to the existing `armedModifiers` property:

```swift
#if os(iOS)
/// Whether the software keyboard is currently on screen.
///
/// Driven by the system's show/hide notifications rather than by tracking our
/// own `dismissKeyboard()` calls, so a keyboard dismissed by the system — a
/// hardware keyboard being attached, say — is observed too.
@Published private(set) var keyboardVisible = false

/// Whether a hardware keyboard is attached. When one is, no software keyboard
/// appears and no show/hide notification ever fires, so `keyboardVisible`
/// stays false and must not be read as "there is room to reclaim".
var hardwareKeyboardAttached: Bool { GCKeyboard.coalesced != nil }
#endif
```

Add `import GameController` to the `#if !os(macOS)` import block at the top.

- [ ] **Step 2: Observe the notifications**

In `init`, inside the existing `#if os(iOS)` block after
`terminalView.inputAccessoryView = nil`:

```swift
let center = NotificationCenter.default
center.addObserver(forName: UIResponder.keyboardWillShowNotification,
                   object: nil, queue: .main) { [weak self] _ in
    MainActor.assumeIsolated { self?.keyboardVisible = true }
}
center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                   object: nil, queue: .main) { [weak self] _ in
    MainActor.assumeIsolated { self?.keyboardVisible = false }
}
```

- [ ] **Step 3: Add the dismiss method**

Add near the existing `send(_:)` method:

```swift
#if os(iOS)
/// Put the software keyboard away, giving its height back to the terminal.
///
/// There is no matching `showKeyboard()`: SwiftTerm's own single-tap handler
/// already calls `becomeFirstResponder()`, so tapping the terminal brings it
/// back.
func dismissKeyboard() {
    _ = terminalView.resignFirstResponder()
}
#endif
```

- [ ] **Step 4: Verify it compiles for both platforms**

```bash
swift build
```
Expected: builds clean. (`swift build` covers SloopKit; the app targets are
built in Xcode and are exercised in Task 3.)

- [ ] **Step 5: Commit**

```bash
git add App/Sloop/Views/TerminalController.swift
git commit -m "Terminal: let the keyboard be dismissed, and track whether it's up"
```

---

### Task 3: Collapse the smart-keys bar when the keyboard is down

Completes part A. After this task the app is shippable and has recovered the
larger share of the rows, independent of whether part B ever lands.

**Files:**
- Create: `App/Sloop/Views/Keyboard/FloatingKeyPill.swift`
- Modify: `App/Sloop/Views/TerminalPane.swift`
- Move: `App/Sloop/Views/KeyboardAccessoryBar.swift` → `App/Sloop/Views/Keyboard/KeyboardAccessoryBar.swift`

**Interfaces:**
- Consumes: `TerminalController.dismissKeyboard()`, `.keyboardVisible`,
  `.hardwareKeyboardAttached` (Task 2); `KeyEncoder.bytes(for:modifiers:applicationCursor:)`.
- Produces: `FloatingKeyPill(send:applicationCursor:restore:)`. Task 7 reuses
  nothing from it, but Task 8's setting changes which of the two bars appears.

- [ ] **Step 1: Move the existing bar into the new directory**

```bash
mkdir -p App/Sloop/Views/Keyboard
git mv App/Sloop/Views/KeyboardAccessoryBar.swift App/Sloop/Views/Keyboard/
```

No code change — `App/Sloop` is globbed by `project.yml`, so the move needs no
project edit.

- [ ] **Step 2: Add a dismiss key to the existing bar**

The bar is the natural home for it, and this is the one idea worth taking from
Blink (their `hideKB` key). In `KeyboardAccessoryBar.body`, insert immediately
before the `divider` that precedes `✕ tab`:

```swift
special("⌨︎↓") { dismissKeyboard() }
```

And add the property next to `closeTab`:

```swift
/// Put the keyboard away. The single biggest recovery of terminal rows
/// available, and until now there was no way to do it at all.
var dismissKeyboard: () -> Void = {}
```

- [ ] **Step 3: Create the floating pill**

Create `App/Sloop/Views/Keyboard/FloatingKeyPill.swift`:

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if os(iOS)
import SwiftUI
import SloopKit

/// What the smart-keys bar collapses to once the keyboard is dismissed.
///
/// A bar in the layout costs 44pt of terminal whether or not it is being used.
/// While reading output you need almost none of it — so this floats *over* the
/// terminal instead, costing no rows, and carries only the keys that matter
/// when you are reading rather than typing: paging, and the way back.
struct FloatingKeyPill: View {
    let send: (ArraySlice<UInt8>) -> Void
    var applicationCursor: () -> Bool = { false }
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            key("pgup") { emit(.pageUp) }
            key("pgdn") { emit(.pageDown) }
            Divider().frame(height: 18)
            Button(action: restore) {
                Image(systemName: "keyboard")
                    .font(.footnote)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show keyboard")
        }
        .padding(.horizontal, 4)
        .background(.thinMaterial, in: Capsule())
        .opacity(0.85)
    }

    private func emit(_ terminalKey: TerminalKey) {
        send(KeyEncoder.bytes(for: terminalKey,
                              applicationCursor: applicationCursor())[...])
    }

    private func key(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
#endif
```

- [ ] **Step 4: Swap the bar for the pill in TerminalPane**

Replace the `#if os(iOS)` block inside `TerminalPane.body`'s `VStack` with a
conditional, and add the pill as an overlay on the whole pane.

The `hardwareKeyboardAttached` check is load-bearing: with a hardware keyboard
no show/hide notification fires, so `keyboardVisible` is false even though there
is no keyboard height to reclaim. Collapsing the bar there would regress the
behaviour `TerminalController`'s `inputAccessoryView = nil` comment protects.

```swift
var body: some View {
    VStack(spacing: 0) {
        ConnectionStatusBar(state: controller.state) { controller.reconnect() }
        SwiftTermView(controller: controller)
        #if os(iOS)
        if showsFullBar {
            KeyboardAccessoryBar(send: { controller.send($0) },
                                 applicationCursor: { controller.applicationCursor },
                                 armed: $controller.armedModifiers,
                                 closeTab: { confirmingClose = true },
                                 dismissKeyboard: { controller.dismissKeyboard() })
        }
        #endif
    }
    #if os(iOS)
    .overlay(alignment: .bottomTrailing) {
        if !showsFullBar {
            FloatingKeyPill(send: { controller.send($0) },
                            applicationCursor: { controller.applicationCursor },
                            restore: { _ = controller.terminalView.becomeFirstResponder() })
                .padding(.trailing, 8)
                .padding(.bottom, 8)
        }
    }
    #endif
    // ... existing .confirmationDialog unchanged
}

#if os(iOS)
/// The full bar earns its 44pt only while you are typing. A hardware keyboard
/// counts as typing: no software keyboard appears, so there is no height to
/// reclaim, and the bar is the only place those keys exist.
private var showsFullBar: Bool {
    controller.keyboardVisible || controller.hardwareKeyboardAttached
}
#endif
```

- [ ] **Step 5: Verify on device**

Build to hardware and confirm, on both an iPhone and an iPad in landscape:

1. Tapping `⌨︎↓` dismisses the keyboard; the bar disappears and the pill appears.
2. The terminal grows — visibly more rows, and the remote reflows (run `top` or
   `vim` to see it redraw).
3. Tapping the terminal restores the keyboard and the full bar.
4. `pgup`/`pgdn` on the pill work inside `less`.
5. With a hardware keyboard attached, the **full bar stays** and the pill never
   appears.

- [ ] **Step 6: Commit**

```bash
git add App/Sloop/Views/Keyboard/ App/Sloop/Views/TerminalPane.swift
git commit -m "iOS: let the keyboard go away, and collapse the bar when it does"
```

---

### Task 4: The `KeyCap` model

First task of part B. Pure SloopKit, fully unit-tested.

**Files:**
- Create: `Sources/SloopKit/Terminal/KeyCap.swift`
- Test: `Tests/SloopKitTests/KeyCapTests.swift`

**Interfaces:**
- Consumes: `TerminalKey`, `KeyModifiers` from `KeyEncoder.swift`.
- Produces: `KeyCap` with `.primary`, `.secondary`, `.width`, `.repeats`;
  nested `KeyCap.Value` (`.character`, `.key`, `.modifier`, `.command`),
  `KeyCap.Command` (`.dismissKeyboard`, `.closeTab`), `KeyCap.Width`
  (`.unit`, `.wide(Double)`, `.flexible`); and the convenience constructors
  `KeyCap.character(_:secondary:)`, `KeyCap.key(_:width:repeats:)`,
  `KeyCap.modifier(_:)`, `KeyCap.command(_:width:)`. Tasks 5, 6, 7 all consume
  these exact names.

- [ ] **Step 1: Write the failing test**

Create `Tests/SloopKitTests/KeyCapTests.swift`:

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class KeyCapTests: XCTestCase {

    func testCharacterCapDefaultsToUnitWidthAndNoRepeat() {
        let cap = KeyCap.character("q")
        XCTAssertEqual(cap.primary, .character("q"))
        XCTAssertNil(cap.secondary)
        XCTAssertEqual(cap.width, .unit)
        XCTAssertFalse(cap.repeats)
    }

    func testCharacterCapCarriesASecondaryValue() {
        let cap = KeyCap.character("1", secondary: .character("~"))
        XCTAssertEqual(cap.primary, .character("1"))
        XCTAssertEqual(cap.secondary, .character("~"))
    }

    func testSpecialKeyCapCanRepeatAndBeWide() {
        let cap = KeyCap.key(.backspace, width: .wide(1.5), repeats: true)
        XCTAssertEqual(cap.primary, .key(.backspace))
        XCTAssertEqual(cap.width, .wide(1.5))
        XCTAssertTrue(cap.repeats)
    }

    func testModifierAndCommandCaps() {
        XCTAssertEqual(KeyCap.modifier(.control).primary, .modifier(.control))
        XCTAssertEqual(KeyCap.command(.dismissKeyboard).primary,
                       .command(.dismissKeyboard))
    }

    /// The characters a cap can produce, which the layout parity test in
    /// Task 5 sums over a whole layout.
    func testReachableCharactersCoversPrimaryAndSecondary() {
        XCTAssertEqual(KeyCap.character("q").reachableCharacters, ["q"])
        XCTAssertEqual(KeyCap.character("1", secondary: .character("~"))
                        .reachableCharacters, ["1", "~"])
        XCTAssertEqual(KeyCap.key(.escape).reachableCharacters, [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KeyCapTests`
Expected: FAIL — `cannot find 'KeyCap' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SloopKit/Terminal/KeyCap.swift`:

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// One key on a software keyboard: what it is, not what it emits.
///
/// Deliberately inert. A cap names a value; `KeyEncoder` alone decides the
/// bytes, so the xterm rules that live there — Ctrl+digit, `key & 0x1F`,
/// DECCKM cursor keys — are never reimplemented alongside a layout table.
public struct KeyCap: Equatable, Sendable {

    /// What pressing a key means.
    public enum Value: Equatable, Sendable {
        /// A printable character, encoded via `KeyEncoder.bytes(for:modifiers:)`.
        case character(Character)
        /// A non-character key, encoded via
        /// `KeyEncoder.bytes(for:modifiers:applicationCursor:)`.
        case key(TerminalKey)
        /// Arms a sticky modifier for the next key. Emits nothing itself.
        case modifier(KeyModifiers)
        /// An app-level action. Emits nothing to the remote.
        case command(Command)
    }

    /// Actions the keyboard asks the app to take, rather than sending onward.
    public enum Command: Equatable, Sendable {
        case dismissKeyboard
        case closeTab
    }

    /// How much horizontal room a key takes, in grid slots.
    public enum Width: Equatable, Sendable {
        case unit
        case wide(Double)
        /// Absorbs whatever width is left in the row — the space bar. At most
        /// one per row; `KeyboardLayout` tests enforce that.
        case flexible
    }

    public let primary: Value
    /// Reached by dragging up from the key. Nil where a layout gives symbols
    /// their own row instead of hiding them behind a gesture.
    public let secondary: Value?
    public let width: Width
    /// Whether press-and-hold repeats — true for backspace and arrows, where
    /// holding is how the key is normally used.
    public let repeats: Bool

    public init(primary: Value,
                secondary: Value? = nil,
                width: Width = .unit,
                repeats: Bool = false) {
        self.primary = primary
        self.secondary = secondary
        self.width = width
        self.repeats = repeats
    }

    // MARK: Convenience constructors

    public static func character(_ character: Character,
                                 secondary: Value? = nil,
                                 width: Width = .unit) -> Self {
        Self(primary: .character(character), secondary: secondary, width: width)
    }

    public static func key(_ terminalKey: TerminalKey,
                           width: Width = .unit,
                           repeats: Bool = false) -> Self {
        Self(primary: .key(terminalKey), width: width, repeats: repeats)
    }

    public static func modifier(_ modifiers: KeyModifiers,
                                width: Width = .unit) -> Self {
        Self(primary: .modifier(modifiers), width: width)
    }

    public static func command(_ command: Command,
                               width: Width = .unit) -> Self {
        Self(primary: .command(command), width: width)
    }

    /// Every character this cap can produce, by tap or by drag. Used by the
    /// layout parity test to prove the phone and tablet tables reach the same
    /// character set.
    public var reachableCharacters: Set<Character> {
        var result: Set<Character> = []
        if case .character(let c) = primary { result.insert(c) }
        // `.some(...)` is required: `secondary` is an Optional, and matching a
        // bare case pattern against it does not compile.
        if case .some(.character(let c)) = secondary { result.insert(c) }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter KeyCapTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SloopKit/Terminal/KeyCap.swift Tests/SloopKitTests/KeyCapTests.swift
git commit -m "SloopKit: add KeyCap, a key described without deciding its bytes"
```

---

### Task 5: `KeyboardLayout` and the shift map

The heart of part B: the adaptive layout tables, plus the US QWERTY shift
mapping that `KeyEncoder` deliberately does not do.

**Why the shift map lives here:** `KeyEncoder.bytes(for: Character, modifiers:)`
ignores `.shift` — correctly, because a terminal receives `A`, not shift+`a`. So
a shifted character must be resolved to the actual character *before* encoding.
That resolution is US-QWERTY keyboard knowledge, which is this file's subject.

**Files:**
- Create: `Sources/SloopKit/Terminal/KeyboardLayout.swift`
- Test: `Tests/SloopKitTests/KeyboardLayoutTests.swift`

**Interfaces:**
- Consumes: `KeyCap` and its nested types (Task 4); the measurements written
  into the spec by Task 1.
- Produces: `KeyboardLayout` with `.rows: [[KeyCap]]` and `.rowHeight: Double`;
  `KeyboardLayout.Context` with `.idiom` (`.phone`/`.pad`), `.orientation`
  (`.portrait`/`.landscape`), `.width: Double`;
  `KeyboardLayout.resolve(for:) -> KeyboardLayout`; and
  `KeyboardLayout.shifted(_: Character) -> Character`. Tasks 6 and 7 consume all.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SloopKitTests/KeyboardLayoutTests.swift`:

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import XCTest
@testable import SloopKit

final class KeyboardLayoutTests: XCTestCase {

    private let padLandscape = KeyboardLayout.Context(
        idiom: .pad, orientation: .landscape, width: 1194)
    private let padPortrait = KeyboardLayout.Context(
        idiom: .pad, orientation: .portrait, width: 834)
    private let phonePortrait = KeyboardLayout.Context(
        idiom: .phone, orientation: .portrait, width: 393)
    private let phoneLandscape = KeyboardLayout.Context(
        idiom: .phone, orientation: .landscape, width: 852)

    // MARK: Shape

    func testPadGetsFiveRowsIncludingADedicatedSymbolRow() {
        XCTAssertEqual(KeyboardLayout.resolve(for: padLandscape).rows.count, 5)
        XCTAssertEqual(KeyboardLayout.resolve(for: padPortrait).rows.count, 5)
    }

    func testPhoneDropsTheSymbolRow() {
        XCTAssertEqual(KeyboardLayout.resolve(for: phonePortrait).rows.count, 4)
        XCTAssertEqual(KeyboardLayout.resolve(for: phoneLandscape).rows.count, 4)
    }

    func testPadHidesNothingBehindAGesture() {
        for cap in KeyboardLayout.resolve(for: padLandscape).rows.flatMap({ $0 }) {
            XCTAssertNil(cap.secondary,
                         "iPad has room for a symbol row; nothing should need a drag")
        }
    }

    func testPhoneUsesSecondariesToReplaceTheSymbolRow() {
        let caps = KeyboardLayout.resolve(for: phonePortrait).rows.flatMap { $0 }
        XCTAssertFalse(caps.filter { $0.secondary != nil }.isEmpty)
    }

    // MARK: The invariant that keeps the two tables honest

    func testPhoneAndPadReachTheSameCharacters() {
        func characters(_ context: KeyboardLayout.Context) -> Set<Character> {
            KeyboardLayout.resolve(for: context).rows
                .flatMap { $0 }
                .reduce(into: Set<Character>()) { $0.formUnion($1.reachableCharacters) }
        }
        XCTAssertEqual(characters(phonePortrait), characters(padLandscape),
                       "Dropping the symbol row must not drop any character")
    }

    func testEveryShellCharacterIsReachable() {
        // The characters a shell actually needs, beyond letters and digits.
        let required: Set<Character> = Set("~`|\\/[]{}<>-_=+;:'\",.")
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let reachable = KeyboardLayout.resolve(for: context).rows
                .flatMap { $0 }
                .reduce(into: Set<Character>()) { $0.formUnion($1.reachableCharacters) }
            XCTAssertTrue(required.isSubset(of: reachable),
                          "missing \(required.subtracting(reachable)) in \(context)")
        }
    }

    func testLettersAndDigitsAreReachableEverywhere() {
        let required = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let reachable = KeyboardLayout.resolve(for: context).rows
                .flatMap { $0 }
                .reduce(into: Set<Character>()) { $0.formUnion($1.reachableCharacters) }
            XCTAssertTrue(required.isSubset(of: reachable))
        }
    }

    // MARK: Well-formedness

    func testAtMostOneFlexibleKeyPerRow() {
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            for (index, row) in KeyboardLayout.resolve(for: context).rows.enumerated() {
                let flexible = row.filter { $0.width == .flexible }.count
                XCTAssertLessThanOrEqual(flexible, 1, "row \(index) of \(context)")
            }
        }
    }

    func testNoDuplicateCharacterWithinALayout() {
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            var seen: Set<Character> = []
            for cap in KeyboardLayout.resolve(for: context).rows.flatMap({ $0 }) {
                for character in cap.reachableCharacters {
                    XCTAssertTrue(seen.insert(character).inserted,
                                  "'\(character)' appears twice in \(context)")
                }
            }
        }
    }

    func testEveryLayoutCanDismissItself() {
        for context in [padLandscape, padPortrait, phonePortrait, phoneLandscape] {
            let caps = KeyboardLayout.resolve(for: context).rows.flatMap { $0 }
            XCTAssertTrue(caps.contains { $0.primary == .command(.dismissKeyboard) },
                          "no way back to the terminal in \(context)")
        }
    }

    func testBackspaceAndArrowsRepeat() {
        for context in [padLandscape, phonePortrait] {
            let caps = KeyboardLayout.resolve(for: context).rows.flatMap { $0 }
            for value in [KeyCap.Value.key(.backspace), .key(.left), .key(.up)] {
                let cap = caps.first { $0.primary == value }
                XCTAssertNotNil(cap, "\(value) missing from \(context)")
                XCTAssertEqual(cap?.repeats, true, "\(value) should repeat")
            }
        }
    }

    // MARK: Row height

    func testRowHeightIsShorterOnPadThanPhonePortrait() {
        // iPad keys are wide, so they can afford to be short. iPhone portrait
        // keys are narrow and need height to stay hittable.
        XCTAssertLessThan(KeyboardLayout.resolve(for: padLandscape).rowHeight,
                          KeyboardLayout.resolve(for: phonePortrait).rowHeight)
    }

    func testPhoneLandscapeUsesShorterRowsThanPhonePortrait() {
        // A 4-row keyboard at portrait height would eat over half of a
        // ~393pt-tall landscape phone screen.
        XCTAssertLessThan(KeyboardLayout.resolve(for: phoneLandscape).rowHeight,
                          KeyboardLayout.resolve(for: phonePortrait).rowHeight)
    }

    // MARK: Shift

    func testShiftedLettersUpperCase() {
        XCTAssertEqual(KeyboardLayout.shifted("a"), "A")
        XCTAssertEqual(KeyboardLayout.shifted("z"), "Z")
    }

    func testShiftedDigitsFollowUSQWERTY() {
        XCTAssertEqual(KeyboardLayout.shifted("1"), "!")
        XCTAssertEqual(KeyboardLayout.shifted("2"), "@")
        XCTAssertEqual(KeyboardLayout.shifted("3"), "#")
        XCTAssertEqual(KeyboardLayout.shifted("4"), "$")
        XCTAssertEqual(KeyboardLayout.shifted("5"), "%")
        XCTAssertEqual(KeyboardLayout.shifted("6"), "^")
        XCTAssertEqual(KeyboardLayout.shifted("7"), "&")
        XCTAssertEqual(KeyboardLayout.shifted("8"), "*")
        XCTAssertEqual(KeyboardLayout.shifted("9"), "(")
        XCTAssertEqual(KeyboardLayout.shifted("0"), ")")
    }

    func testShiftedPunctuationFollowsUSQWERTY() {
        XCTAssertEqual(KeyboardLayout.shifted("-"), "_")
        XCTAssertEqual(KeyboardLayout.shifted("="), "+")
        XCTAssertEqual(KeyboardLayout.shifted("["), "{")
        XCTAssertEqual(KeyboardLayout.shifted("]"), "}")
        XCTAssertEqual(KeyboardLayout.shifted("\\"), "|")
        XCTAssertEqual(KeyboardLayout.shifted(";"), ":")
        XCTAssertEqual(KeyboardLayout.shifted("'"), "\"")
        XCTAssertEqual(KeyboardLayout.shifted(","), "<")
        XCTAssertEqual(KeyboardLayout.shifted("."), ">")
        XCTAssertEqual(KeyboardLayout.shifted("/"), "?")
        XCTAssertEqual(KeyboardLayout.shifted("`"), "~")
    }

    func testShiftLeavesAlreadyShiftedCharactersAlone() {
        XCTAssertEqual(KeyboardLayout.shifted("A"), "A")
        XCTAssertEqual(KeyboardLayout.shifted("!"), "!")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeyboardLayoutTests`
Expected: FAIL — `cannot find 'KeyboardLayout' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SloopKit/Terminal/KeyboardLayout.swift`.

**Row heights:** the literals below are starting points. Replace them with
values derived from Task 1's measurements before considering this task done —
that is the entire reason Task 1 exists.

**Symbol placement on iPhone:** the pairing below follows keyboard convention
(`1`→`` ` ``, `-`→`_`, `[`→`{`) because a learnable mapping beats an optimal
one. Any assignment that keeps `testPhoneAndPadReachTheSameCharacters` green is
acceptable if you prefer another.

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

import Foundation

/// A resolved software-keyboard layout: which keys, in which rows, how tall.
///
/// The layout varies by device because the constraint does. An iPad in
/// landscape has width to spare, so symbols get a row of their own and nothing
/// hides behind a gesture. A phone does not, so those same symbols ride on a
/// drag-up from the digit row — fewer rows, same reachable characters. That
/// equivalence is not a convention to be remembered; it is enforced by
/// `KeyboardLayoutTests.testPhoneAndPadReachTheSameCharacters`.
public struct KeyboardLayout: Equatable, Sendable {
    public let rows: [[KeyCap]]
    /// Height of one key row, in points.
    public let rowHeight: Double

    /// What a layout varies on.
    public struct Context: Equatable, Sendable, CustomStringConvertible {
        public enum Idiom: Equatable, Sendable { case phone, pad }
        public enum Orientation: Equatable, Sendable { case portrait, landscape }

        public let idiom: Idiom
        public let orientation: Orientation
        public let width: Double

        public init(idiom: Idiom, orientation: Orientation, width: Double) {
            self.idiom = idiom
            self.orientation = orientation
            self.width = width
        }

        public var description: String { "\(idiom)/\(orientation)@\(Int(width))" }
    }

    /// The symbols a shell needs constantly and a prose keyboard buries.
    /// On iPad these are a row; on iPhone they become drag-up secondaries.
    private static let symbols: [Character] =
        ["~", "`", "|", "\\", "/", "[", "]", "{", "}", "<",
         ">", "-", "_", "=", "+", ";", ":", "'"]

    public static func resolve(for context: Context) -> KeyboardLayout {
        switch context.idiom {
        case .pad:   return pad(context)
        case .phone: return phone(context)
        }
    }

    // MARK: iPad — five rows, symbols visible

    private static func pad(_ context: Context) -> KeyboardLayout {
        let symbolRow = symbols.map { KeyCap.character($0) } + [KeyCap.character("\"")]

        return KeyboardLayout(
            rows: [
                symbolRow,
                [.key(.escape)]
                    + "1234567890".map { KeyCap.character($0) }
                    + [.key(.backspace, width: .wide(1.5), repeats: true)],
                [.key(.tab)]
                    + "qwertyuiop".map { KeyCap.character($0) }
                    + [.key(.up, repeats: true)],
                [.modifier(.control)]
                    + "asdfghjkl".map { KeyCap.character($0) }
                    + [.key(.return, width: .wide(1.5)), .key(.down, repeats: true)],
                [.modifier(.option), .modifier(.shift)]
                    + "zxcvbnm".map { KeyCap.character($0) }
                    + [.character(","), .character("."),
                       .character(" ", width: .flexible),
                       .key(.left, repeats: true), .key(.right, repeats: true),
                       .command(.dismissKeyboard)],
            ],
            // iPad keys are wide, so they can be short without becoming hard
            // to hit — which is the whole point, since height is what a
            // terminal wants back.
            rowHeight: context.orientation == .landscape ? 38 : 40)
    }

    // MARK: iPhone — four rows, symbols on drag

    private static func phone(_ context: Context) -> KeyboardLayout {
        // Convention-led pairings: shift-row order for the digits, and the
        // bracket/quote partners where one exists.
        let digits: [KeyCap] = [
            .character("1", secondary: .character("~")),
            .character("2", secondary: .character("`")),
            .character("3", secondary: .character("|")),
            .character("4", secondary: .character("\\")),
            .character("5", secondary: .character("/")),
            .character("6", secondary: .character("[")),
            .character("7", secondary: .character("]")),
            .character("8", secondary: .character("{")),
            .character("9", secondary: .character("}")),
            .character("0", secondary: .character("<")),
        ]
        let homeRow: [KeyCap] = [
            .character("a", secondary: .character(">")),
            .character("s", secondary: .character("-")),
            .character("d", secondary: .character("_")),
            .character("f", secondary: .character("=")),
            .character("g", secondary: .character("+")),
            .character("h", secondary: .character(";")),
            .character("j", secondary: .character(":")),
            .character("k", secondary: .character("'")),
            .character("l", secondary: .character("\"")),
        ]

        return KeyboardLayout(
            rows: [
                [.key(.escape)] + digits
                    + [.key(.backspace, repeats: true)],
                [.key(.tab)] + "qwertyuiop".map { KeyCap.character($0) },
                [.modifier(.control)] + homeRow + [.key(.return)],
                [.modifier(.option), .modifier(.shift)]
                    + "zxcvbnm".map { KeyCap.character($0) }
                    + [.character(","), .character("."),
                       .character(" ", width: .flexible),
                       .key(.left, repeats: true), .key(.down, repeats: true),
                       .key(.up, repeats: true), .key(.right, repeats: true),
                       .command(.dismissKeyboard)],
            ],
            // Portrait keys are ~39pt wide on a 393pt screen and need height to
            // stay hittable. Landscape has to give some of it back: four rows
            // at portrait height would eat over half a ~393pt-tall screen.
            rowHeight: context.orientation == .portrait ? 52 : 40)
    }

    // MARK: Shift

    /// The US QWERTY shifted form of a character.
    ///
    /// This lives here, not in `KeyEncoder`, because it is keyboard knowledge
    /// rather than terminal knowledge: a terminal is sent `A`, never shift+`a`,
    /// so shift must be resolved to a character before anything is encoded.
    /// `KeyEncoder.bytes(for:modifiers:)` accordingly ignores `.shift`.
    public static func shifted(_ character: Character) -> Character {
        if let upper = character.uppercased().first, upper != character {
            return upper
        }
        return punctuationShifts[character] ?? character
    }

    private static let punctuationShifts: [Character: Character] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
        "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
        ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeyboardLayoutTests`
Expected: PASS.

Two tests are expected to need iteration — treat their failures as the tables
being wrong, not the tests:
- `testPhoneAndPadReachTheSameCharacters` fails if a symbol has no phone home.
  Fix by giving it a `secondary` slot, not by weakening the test.
- `testNoDuplicateCharacterWithinALayout` fails if a symbol appears both in the
  iPad symbol row and as a plain key (`,` `.` are easy to double up).

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS — all previous tests plus the new ones.

- [ ] **Step 6: Commit**

```bash
git add Sources/SloopKit/Terminal/KeyboardLayout.swift Tests/SloopKitTests/KeyboardLayoutTests.swift
git commit -m "SloopKit: resolve keyboard layouts per device, with a shift map"
```

---

### Task 6: `KeyCapView` — rendering and interacting with one key

**Files:**
- Create: `App/Sloop/Views/Keyboard/KeyCapView.swift`

**Interfaces:**
- Consumes: `KeyCap`, `KeyCap.Value`, `KeyCap.Width`, `KeyboardLayout.shifted(_:)`.
- Produces: `KeyCapView: UIControl` with `init(cap:delegate:)`, the protocol
  `KeyCapViewDelegate` with the single method
  `keyCapView(_:didProduce:)` taking a `KeyCap.Value`, and
  `KeyCapView.setArmed(_ isArmed: Bool)`. Task 7 consumes all of these.

No unit test: this is gesture and timer behaviour on a `UIControl`, with no seam
a unit test reaches without a running app. Verified on device in Task 7.

- [ ] **Step 1: Create the view**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if os(iOS)
import UIKit
import SloopKit

/// Receives what a key produced. The view never encodes or sends anything
/// itself — it reports a `KeyCap.Value` and lets the keyboard decide.
protocol KeyCapViewDelegate: AnyObject {
    func keyCapView(_ view: KeyCapView, didProduce value: KeyCap.Value)
}

/// One key. Three interactions, because a terminal key is asked to do more
/// than a prose one:
///
/// - **tap** → the primary value
/// - **drag up** past a threshold → the secondary value, where the layout put
///   a symbol behind a gesture rather than spend a row on it
/// - **press and hold** → repeat, for the keys that are normally used by
///   holding them (backspace, arrows)
final class KeyCapView: UIControl {
    private static let dragThreshold: CGFloat = 20
    private static let repeatDelay: TimeInterval = 0.4
    private static let repeatInterval: TimeInterval = 0.07

    let cap: KeyCap
    private weak var delegate: KeyCapViewDelegate?

    private let primaryLabel = UILabel()
    private let secondaryLabel = UILabel()
    private var repeatTimer: Timer?
    private var didDrag = false

    init(cap: KeyCap, delegate: KeyCapViewDelegate) {
        self.cap = cap
        self.delegate = delegate
        super.init(frame: .zero)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Highlight a sticky modifier that is currently armed.
    func setArmed(_ isArmed: Bool) {
        backgroundColor = isArmed ? .tintColor : .secondarySystemFill
        primaryLabel.textColor = isArmed ? .white : .label
    }

    // MARK: Appearance

    private func buildUI() {
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = 5
        isMultipleTouchEnabled = false

        primaryLabel.text = Self.label(for: cap.primary)
        primaryLabel.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        primaryLabel.textAlignment = .center
        primaryLabel.textColor = .label
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(primaryLabel)

        NSLayoutConstraint.activate([
            primaryLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            primaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        guard let secondary = cap.secondary else { return }
        // Shown small and high: it advertises the drag target, so a symbol
        // behind a gesture is still discoverable rather than folklore.
        secondaryLabel.text = Self.label(for: secondary)
        secondaryLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        secondaryLabel.textColor = .secondaryLabel
        secondaryLabel.textAlignment = .center
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(secondaryLabel)

        NSLayoutConstraint.activate([
            secondaryLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            secondaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
        ])
    }

    private static func label(for value: KeyCap.Value) -> String {
        switch value {
        case .character(let c):        return c == " " ? "space" : String(c)
        case .key(let key):            return label(for: key)
        case .modifier(let modifiers): return label(for: modifiers)
        case .command(let command):
            switch command {
            case .dismissKeyboard: return "⌨︎↓"
            case .closeTab:        return "✕"
            }
        }
    }

    private static func label(for key: TerminalKey) -> String {
        switch key {
        case .escape:      return "esc"
        case .tab:         return "⇥"
        case .return:      return "⏎"
        case .backspace:   return "⌫"
        case .delete:      return "⌦"
        case .up:          return "↑"
        case .down:        return "↓"
        case .left:        return "←"
        case .right:       return "→"
        case .home:        return "home"
        case .end:         return "end"
        case .pageUp:      return "pgup"
        case .pageDown:    return "pgdn"
        case .function(let n): return "F\(n)"
        }
    }

    private static func label(for modifiers: KeyModifiers) -> String {
        if modifiers.contains(.control) { return "⌃" }
        if modifiers.contains(.option)  { return "⌥" }
        if modifiers.contains(.shift)   { return "⇧" }
        return "?"
    }

    // MARK: Touch handling

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        didDrag = false
        alpha = 0.6
        UIDevice.current.playInputClick()
        if cap.repeats { startRepeating() }
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard cap.secondary != nil else { return true }
        let rise = touch.previousLocation(in: self).y - touch.location(in: self).y
        if rise > Self.dragThreshold { didDrag = true }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        alpha = 1
        stopRepeating()
        // A repeating key already fired on touch-down and on every tick;
        // firing again here would emit one extra character per press.
        guard !cap.repeats else { return }
        if didDrag, let secondary = cap.secondary {
            delegate?.keyCapView(self, didProduce: secondary)
        } else {
            delegate?.keyCapView(self, didProduce: cap.primary)
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        alpha = 1
        stopRepeating()
    }

    // MARK: Repeat

    private func startRepeating() {
        delegate?.keyCapView(self, didProduce: cap.primary)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay,
                                           repeats: false) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(
                withTimeInterval: Self.repeatInterval, repeats: true
            ) { [weak self] _ in
                guard let self else { return }
                self.delegate?.keyCapView(self, didProduce: self.cap.primary)
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    deinit { repeatTimer?.invalidate() }
}
#endif
```

- [ ] **Step 2: Verify it compiles**

Build the iOS app target in Xcode (⌘B), or:

```bash
xcodebuild -project Sloop.xcodeproj -scheme Sloop_iOS \
  -destination 'generic/platform=iOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add App/Sloop/Views/Keyboard/KeyCapView.swift
git commit -m "Keyboard: one key that taps, drags for its second value, and repeats"
```

---

### Task 7: `CompactKeyboardView` — assemble and install

**Files:**
- Create: `App/Sloop/Views/Keyboard/CompactKeyboardView.swift`
- Modify: `App/Sloop/Views/TerminalController.swift`

**Interfaces:**
- Consumes: `KeyboardLayout.resolve(for:)`, `KeyboardLayout.shifted(_:)`,
  `KeyCapView`, `KeyCapViewDelegate`, `KeyEncoder`,
  `TerminalController.armedModifiers`, `.applicationCursor`, `.send(_:)`,
  `.dismissKeyboard()`.
- Produces: `CompactKeyboardView(controller:)` and
  `TerminalController.setCompactKeyboard(_ enabled: Bool)`. Task 8 calls the latter.

- [ ] **Step 1: Create the keyboard view**

```swift
// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if os(iOS)
import UIKit
import SloopKit

/// A terminal-shaped keyboard, installed as `terminalView.inputView` in place
/// of Apple's.
///
/// The point is height. Apple's keyboard is sized to touch-type prose across
/// the full width of the screen, which on an iPad in landscape means ~353pt
/// spent on keys about 119pt wide — a finger is about 44pt, so the excess is
/// entirely vertical, and vertical is the axis a terminal wants back.
///
/// This view sizes itself from the resolved layout instead of accepting the
/// system's height, and folds the smart-keys bar in, so no separate strip
/// stacks above it.
final class CompactKeyboardView: UIInputView, KeyCapViewDelegate {
    private weak var controller: TerminalController?
    private var layout: KeyboardLayout
    private var keyViews: [KeyCapView] = []

    init(controller: TerminalController) {
        self.controller = controller
        self.layout = KeyboardLayout.resolve(for: Self.currentContext())
        super.init(frame: .zero, inputViewStyle: .keyboard)
        allowsSelfSizing = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: layout.rowHeight * Double(layout.rows.count) + Self.padding * 2)
    }

    private static let padding: Double = 4
    private static let spacing: Double = 3

    // MARK: Layout

    private static func currentContext() -> KeyboardLayout.Context {
        let screen = UIScreen.main.bounds
        return KeyboardLayout.Context(
            idiom: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone,
            orientation: screen.width > screen.height ? .landscape : .portrait,
            width: screen.width)
    }

    private func rebuild() {
        keyViews.forEach { $0.removeFromSuperview() }
        keyViews = []
        for row in layout.rows {
            for cap in row {
                let view = KeyCapView(cap: cap, delegate: self)
                addSubview(view)
                keyViews.append(view)
            }
        }
        refreshArmedState()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }

        var index = 0
        var y = Self.padding
        for row in layout.rows {
            // A row is laid out in grid slots. Fixed-width keys claim their
            // share first; whatever is left goes to the one flexible key, so
            // the space bar absorbs rounding rather than leaving a gap.
            let fixedSlots = row.reduce(0.0) { total, cap in
                switch cap.width {
                case .unit:            return total + 1
                case .wide(let scale): return total + scale
                case .flexible:        return total
                }
            }
            let gaps = Self.spacing * Double(max(row.count - 1, 0))
            let available = Double(bounds.width) - Self.padding * 2 - gaps
            let hasFlexible = row.contains { $0.width == .flexible }
            // Reserve two slots for the flexible key so it stays a usable
            // space bar rather than collapsing to a sliver.
            let slotWidth = available / (fixedSlots + (hasFlexible ? 2 : 0))

            var x = Self.padding
            for cap in row {
                let width: Double
                switch cap.width {
                case .unit:            width = slotWidth
                case .wide(let scale): width = slotWidth * scale
                case .flexible:        width = slotWidth * 2
                }
                keyViews[index].frame = CGRect(
                    x: x, y: y,
                    width: width,
                    height: layout.rowHeight - Self.spacing)
                x += width + Self.spacing
                index += 1
            }
            y += layout.rowHeight
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        let fresh = KeyboardLayout.resolve(for: Self.currentContext())
        guard fresh != layout else { return }
        layout = fresh
        rebuild()
    }

    // MARK: Input

    func keyCapView(_ view: KeyCapView, didProduce value: KeyCap.Value) {
        guard let controller else { return }

        switch value {
        case .modifier(let modifiers):
            // Sticky: tap to arm, tap again to disarm. Shared with the
            // accessory bar via the controller, so both modes behave alike.
            if controller.armedModifiers.contains(modifiers) {
                controller.armedModifiers.remove(modifiers)
            } else {
                controller.armedModifiers.insert(modifiers)
            }
            refreshArmedState()

        case .command(let command):
            switch command {
            case .dismissKeyboard: controller.dismissKeyboard()
            case .closeTab:        break   // routed by TerminalPane, not here
            }

        case .character(let character):
            let armed = controller.armedModifiers
            // Shift is resolved to a character here, never passed onward: a
            // terminal receives 'A', not shift+'a', which is why
            // KeyEncoder ignores .shift for characters.
            let resolved = armed.contains(.shift)
                ? KeyboardLayout.shifted(character)
                : character
            controller.send(
                KeyEncoder.bytes(for: resolved,
                                 modifiers: armed.subtracting(.shift))[...])
            clearArmedModifiers()

        case .key(let terminalKey):
            controller.send(
                KeyEncoder.bytes(for: terminalKey,
                                 modifiers: controller.armedModifiers,
                                 applicationCursor: controller.applicationCursor)[...])
            clearArmedModifiers()
        }
    }

    private func clearArmedModifiers() {
        guard let controller, !controller.armedModifiers.isEmpty else { return }
        controller.armedModifiers = []
        refreshArmedState()
    }

    private func refreshArmedState() {
        let armed = controller?.armedModifiers ?? []
        for view in keyViews {
            guard case .modifier(let modifiers) = view.cap.primary else { continue }
            view.setArmed(armed.contains(modifiers))
        }
    }
}
#endif
```

- [ ] **Step 2: Add the install hook to TerminalController**

Add near `dismissKeyboard()`:

```swift
#if os(iOS)
/// Swap between Apple's keyboard and Sloop's compact one.
///
/// `inputView` is the same hook SwiftTerm's own `KeyboardView` uses; nil means
/// the system keyboard. Reloading is required because UIKit caches the input
/// view for as long as the responder stays first responder.
func setCompactKeyboard(_ enabled: Bool) {
    terminalView.inputView = enabled ? CompactKeyboardView(controller: self) : nil
    if terminalView.isFirstResponder {
        terminalView.reloadInputViews()
    }
}
#endif
```

- [ ] **Step 3: Verify it compiles**

```bash
xcodebuild -project Sloop.xcodeproj -scheme Sloop_iOS \
  -destination 'generic/platform=iOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add App/Sloop/Views/Keyboard/CompactKeyboardView.swift App/Sloop/Views/TerminalController.swift
git commit -m "Keyboard: a compact keyboard sized for a terminal, not for prose"
```

---

### Task 8: The standard/compact setting

Wires part B to a user-visible choice and makes it persist.

**Files:**
- Modify: `Sources/SloopKit/Terminal/TerminalAppearance.swift`
- Modify: `Tests/SloopKitTests/TerminalAppearanceTests.swift`
- Modify: `App/Sloop/Views/TerminalController.swift`
- Modify: `App/Sloop/Views/TerminalSettingsView.swift`

**Interfaces:**
- Consumes: `TerminalController.setCompactKeyboard(_:)` (Task 7).
- Produces: `TerminalAppearance.KeyboardStyle` (`.standard`, `.compact`) and
  `TerminalAppearance.keyboard`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/SloopKitTests/TerminalAppearanceTests.swift`:

```swift
func testKeyboardStyleDefaultsToStandard() {
    XCTAssertEqual(TerminalAppearance.default.keyboard, .standard)
}

func testKeyboardStyleRoundTrips() throws {
    let appearance = TerminalAppearance(fontSize: 14, theme: .dark,
                                        cursor: .bar, keyboard: .compact)
    let data = try JSONEncoder().encode(appearance)
    let decoded = try JSONDecoder().decode(TerminalAppearance.self, from: data)
    XCTAssertEqual(decoded.keyboard, .compact)
}

func testAppearanceStoredBeforeTheKeyboardSettingExistedStillDecodes() throws {
    // A value persisted by an older build has no `keyboard` key at all.
    let json = #"{"fontSize":13,"theme":"dark","cursor":"block"}"#
    let decoded = try JSONDecoder().decode(TerminalAppearance.self,
                                           from: Data(json.utf8))
    XCTAssertEqual(decoded.keyboard, .standard)
    XCTAssertEqual(decoded.theme, .dark)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TerminalAppearanceTests`
Expected: FAIL — no `keyboard` member.

- [ ] **Step 3: Add the property**

In `TerminalAppearance.swift`:

Add the enum after `CursorStyle`:

```swift
/// Which software keyboard a session gets on iOS.
///
/// This is input, not look, and this type documents itself as the terminal's
/// appearance — a deliberate trade. A parallel preferences model and store for
/// a single enum is more structure than the problem earns. If input settings
/// grow (repeat rate, Caps Lock remapping, hardware chords), split them out
/// then and widen this type's doc comment at that point.
public enum KeyboardStyle: String, Codable, CaseIterable, Sendable {
    /// Apple's keyboard, with Sloop's smart-keys bar above it.
    case standard
    /// Sloop's compact keyboard, with the smart-keys bar folded into it.
    case compact
}
```

Then, in order: add `case keyboard` to `CodingKeys`; add
`public var keyboard: KeyboardStyle` after `cursor`; add
`keyboard: KeyboardStyle = .standard` as the last `init` parameter with
`self.keyboard = keyboard`; add to `init(from:)`:

```swift
self.keyboard = try c.decodeIfPresent(KeyboardStyle.self, forKey: .keyboard) ?? .standard
```

And update `default` to `TerminalAppearance(fontSize: 13, theme: .system, cursor: .block, keyboard: .standard)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TerminalAppearanceTests`
Expected: PASS.

- [ ] **Step 5: Apply the setting to live terminals**

In `TerminalController.apply(_:)`, add at the end — kept in its own branch so
the keyboard concern stays separable from font and palette:

```swift
#if os(iOS)
setCompactKeyboard(appearance.keyboard == .compact)
#endif
```

- [ ] **Step 6: Add the picker**

In `TerminalSettingsView.body`, after the `Cursor` section:

```swift
#if os(iOS)
Section("Keyboard") {
    Picker("Style", selection: $store.appearance.keyboard) {
        ForEach(TerminalAppearance.KeyboardStyle.allCases, id: \.self) { style in
            Text(style.rawValue.capitalized).tag(style)
        }
    }
    .pickerStyle(.segmented)

    Text("Compact is shorter, leaving more of the screen for the terminal. "
       + "It is US QWERTY only, and has no dictation or emoji — switch back "
       + "to Standard for those.")
        .font(.footnote)
        .foregroundStyle(.secondary)
}
#endif
```

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Verify on device**

On an iPad in landscape and an iPhone:

1. Switching Standard → Compact swaps the keyboard on an already-open session
   without reconnecting.
2. The compact keyboard is visibly shorter, and the terminal gains rows.
3. iPad shows a symbol row; iPhone shows small drag hints and dragging up on
   `1` produces `~`.
4. `⌃` arms, stays highlighted, applies to the next key, then disarms. `⌃B`
   reaches tmux; `⌃C` interrupts.
5. `⇧` produces capitals and `!` from `1`.
6. Holding `⌫` and the arrows repeats.
7. `⌨︎↓` dismisses, and the setting survives relaunching the app.
8. Rotating rebuilds the layout at the right size.

- [ ] **Step 9: Commit**

```bash
git add Sources/SloopKit/Terminal/TerminalAppearance.swift \
        Tests/SloopKitTests/TerminalAppearanceTests.swift \
        App/Sloop/Views/TerminalController.swift \
        App/Sloop/Views/TerminalSettingsView.swift
git commit -m "Settings: choose between the standard and compact keyboard"
```

---

### Task 9: Update the roadmap

**Files:**
- Modify: `Docs/ROADMAP.md`

- [ ] **Step 1: Move the item out of nice-to-haves**

Delete the `**Custom compact keyboard**` bullet from `## Nice-to-have` and add
to `## M2 — Keyboard & UX`:

```markdown
- [x] Dismissible keyboard — a `⌨︎↓` key and a floating pill that replaces the
      smart-keys bar while the keyboard is down, so the bar stops reserving
      44pt it isn't using.
- [x] Custom compact keyboard — `KeyboardLayout` resolves a terminal-shaped
      layout per device (symbol row on iPad, drag-up symbols on iPhone),
      installed via SwiftTerm's `inputView`. Chosen in Terminal Settings;
      Standard remains the default. Spec:
      `Docs/superpowers/specs/2026-08-17-terminal-rows-design.md`.
```

- [ ] **Step 2: Commit**

```bash
git add Docs/ROADMAP.md
git commit -m "Roadmap: mark the dismissible and compact keyboards done"
```

---

## Natural stopping point

Tasks 1–3 deliver part A on their own: the keyboard becomes dismissible, the bar
stops costing 44pt while it is down, and the larger share of the rows is
recovered on both devices. If part B stalls at Task 1's decision gate, or simply
proves not worth it in use, the branch is still worth merging after Task 3.
