# Architecture

## Layers

```
┌────────────────────────────────────────────┐
│ App/Sloop  (SwiftUI, per-platform thin UI)  │
│  SloopApp → HostListView → TerminalScreen   │
│  SwiftTermView  ⇄  SwiftTerm.TerminalView   │
└──────────────────────┬─────────────────────┘
                       │  Transport protocol
┌──────────────────────┴─────────────────────┐
│ SloopKit  (Foundation only, testable)       │
│  Transport  EchoTransport  TerminalSession  │
│  LibSSH2Transport   MoshBootstrap           │
│  Host  HostStore  Credential  SSHError      │
└─────────────────────────────────────────────┘
```

## The Transport seam

Everything the terminal talks to implements one protocol:

```swift
protocol Transport: AnyObject {
    var onData: ((ArraySlice<UInt8>) -> Void)? { get set }   // remote → terminal
    var onClose: ((Error?) -> Void)? { get set }
    func start()
    func send(_ bytes: ArraySlice<UInt8>)                    // terminal → remote
    func resize(cols: Int, rows: Int)
    func close()
}
```

Implementations:

- **`EchoTransport`** — local, no network. Ships today.
- **`LibSSH2Transport`** — libssh2 shell channel. Skeleton in place.
- **`MoshTransport`** — Mosh SSP over UDP. Not started; `MoshBootstrap` parses
  the handshake it will need.

`SwiftTermView.Coordinator` is the only place the two worlds meet: it implements
`TerminalViewDelegate` (SwiftTerm → us) and pumps `onData` back into the view.

## Why the split

- **Testable core.** SloopKit has no UIKit/AppKit, so `swift test` runs on Linux
  CI and catches regressions in parsing, persistence, and byte handling without
  a simulator.
- **Thin UI.** The SwiftUI layer is mostly wiring; platform differences are a
  handful of `#if os(...)` blocks (keyboard bar on iOS, representable type on
  macOS).
- **One codebase, four platforms.** XcodeGen expands the single app target to
  iOS/tvOS/macOS. Mac gets a native build; it also runs the iOS build directly
  on Apple Silicon.

## Threading

Transports may deliver `onData` off the main thread (SSH/Mosh read loops will).
The coordinator hops to `DispatchQueue.main` before every `feed(...)`. Keep that
invariant when adding transports.
