// Sloop — Copyright (C) 2026 Matthew Szatmary
// GPL-3.0 with additional terms under §7 — see LICENSE and THIRD-PARTY-NOTICES.md

#if os(iOS)
import UIKit
import Combine
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
/// system's height. It does not fold `KeyboardAccessoryBar` in as a subview —
/// instead `TerminalPane` hides that bar once this keyboard is installed
/// (`TerminalController.compactKeyboardActive`), so the two never coexist on
/// screen.
final class CompactKeyboardView: UIInputView, KeyCapViewDelegate, UIInputViewAudioFeedback {
    private weak var controller: TerminalController?
    private var layout: KeyboardLayout
    private var keyViews: [KeyCapView] = []
    /// Keeps the sticky-modifier highlight subscribed to
    /// `controller.armedModifiers` for the view's lifetime — see `init`.
    private var armedModifiersCancellable: AnyCancellable?

    init(controller: TerminalController) {
        self.controller = controller
        self.layout = KeyboardLayout.resolve(for: Self.context(for: UIScreen.main.bounds))
        super.init(frame: .zero, inputViewStyle: .keyboard)
        // `allowsSelfSizing` alone is not enough: the programmatic default of
        // `translatesAutoresizingMaskIntoConstraints == true` makes UIKit
        // synthesise autoresizing constraints pinning this view to its
        // `.zero` init frame, and those outrank `intrinsicContentSize` — the
        // keyboard would never actually take height.
        translatesAutoresizingMaskIntoConstraints = false
        allowsSelfSizing = true
        rebuild()

        // The highlight is driven off the publisher, not pushed manually,
        // because `armedModifiers` is mutated from other places this view
        // doesn't otherwise observe: `KeyboardAccessoryBar.toggle(_:)` and
        // `.emit(_:)` — armed there before the setting was switched to
        // compact, so the value can already be non-empty by the time this
        // view is built — and `TerminalController.send(source:data:)`, which
        // clears it on hardware-keyboard input reaching SwiftTerm directly,
        // bypassing this view entirely. Without this subscription this
        // view's own ⌃ could go stale relative to either — staying lit after
        // the modifier it represents was already cleared elsewhere, with the
        // next character typed here then encoded with a modifier the user
        // can no longer see is armed.
        armedModifiersCancellable = controller.$armedModifiers.sink { [weak self] armed in
            self?.applyArmed(armed)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric,
               height: layout.rowHeight * Double(layout.rows.count) + Self.padding * 2)
    }

    private static let padding: Double = 4
    private static let spacing: Double = 3

    // MARK: Layout

    /// What a layout varies on, resolved from `bounds` — the caller decides
    /// whose: the hosting window's own bounds once this view is attached, or
    /// `UIScreen.main.bounds` as a starting guess before it has one (i.e.
    /// during `init`, before `setCompactKeyboard` installs it). Only
    /// `bounds`' aspect ratio is read (for orientation); the actual width
    /// used to lay out keys comes from this view's own `bounds.width` in
    /// `layoutSubviews`, not from here — see `Context`'s doc comment.
    private static func context(for bounds: CGRect) -> KeyboardLayout.Context {
        KeyboardLayout.Context(
            idiom: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone,
            orientation: bounds.width > bounds.height ? .landscape : .portrait)
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
        // The subscription in `init` only fires on the *next* change to
        // `armedModifiers`; newly built views need today's value applied
        // explicitly, or a rebuild mid-session (rotation, Split View resize)
        // would draw every key unarmed regardless of what's actually armed.
        applyArmed(controller?.armedModifiers ?? [])
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Interface orientation is not itself a trait: on iPad both
        // orientations report the same (regular, regular) size class, so a
        // `traitCollectionDidChange` override never fires there on rotation.
        // Resolving fresh from this view's own window on every layout pass —
        // rather than caching a trait-driven value — catches rotation on
        // every idiom. NOTE: `window` here is this *input view's* window
        // (UIKit gives a keyboard its own window, separate from the app's),
        // not the app's own window — so this does NOT reflect the app's size
        // under Split View or Stage Manager the way it might look like it
        // does. What it does correctly track is orientation, which rotates
        // in lockstep with the app window regardless of which window reports
        // it, and orientation is the only thing read here: the actual width
        // used for layout comes from this view's own `bounds.width` below,
        // not from `Context` (see its doc comment).
        let fresh = KeyboardLayout.resolve(for: Self.context(for: window?.bounds ?? UIScreen.main.bounds))
        if fresh != layout {
            layout = fresh
            rebuild()
        }

        guard bounds.width > 0 else {
            assertionFailure("CompactKeyboardView laid out with zero width")
            return
        }

        let frames = layout.frames(width: Double(bounds.width),
                                   padding: Self.padding,
                                   spacing: Self.spacing)
        // `zip` stops at the shorter sequence rather than trapping on an
        // out-of-range index, which is what made the old hand-rolled index
        // into `keyViews` a hazard in the first place; `frames` and
        // `keyViews` are always built from the same `layout.rows` in the
        // same row-major order, so the two are never actually mismatched,
        // but nothing here depends on that being true to stay safe.
        for (view, frame) in zip(keyViews, frames) {
            view.frame = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
    }

    // MARK: Input

    func keyCapView(_ view: KeyCapView, didProduce value: KeyCap.Value) {
        guard let controller else { return }

        switch value {
        case .modifier(let modifiers):
            // Sticky: tap to arm, tap again to disarm. Shared with the
            // accessory bar via the controller, so both modes behave alike.
            // The highlight updates via the `armedModifiers` subscription in
            // `init`, not here — see that comment for why pushing it
            // manually was the bug.
            if controller.armedModifiers.contains(modifiers) {
                controller.armedModifiers.remove(modifiers)
            } else {
                controller.armedModifiers.insert(modifiers)
            }

        case .functionLayer:
            // Sticky like the modifiers beside it: tap to arm, tap again to
            // disarm, and it clears itself after the key it applies to.
            functionLayerArmed.toggle()
            view.setArmed(functionLayerArmed)
            applyFunctionLayer()

        case .command(let command):
            switch command {
            case .dismissKeyboard:
                // Otherwise a modifier armed right before dismissal stays
                // armed with nothing on screen left to show it: the keyboard
                // (and its highlighted key) is gone, but the next character
                // typed via a reattached keyboard would still be modified.
                clearArmedModifiers()
                controller.dismissKeyboard()

            case .paste:
                // Sent as if typed, which is what paste means in a terminal:
                // the remote decides how to interpret it, exactly as it does
                // for the characters around it. Nothing is sent when the
                // pasteboard holds no text — an image or a file promise is not
                // something a shell can be handed.
                if let text = UIPasteboard.general.string, !text.isEmpty {
                    controller.send(ArraySlice(Array(text.utf8)))
                }
                clearArmedModifiers()

            case .copy:
                // Only what's selected. With no selection there is nothing to
                // copy and no way to guess what was meant, and putting the
                // wrong thing on the pasteboard silently is worse than putting
                // nothing there.
                if let selection = controller.terminalView.getSelection(), !selection.isEmpty {
                    UIPasteboard.general.string = selection
                }
                clearArmedModifiers()

            }

        case .blank:
            break   // a hole in the grid; nothing to send, nothing to arm

        case .character(let character) where functionLayerArmed:
            // fn + a digit is F1–F12, in the arrangement every keyboard without
            // an F-row uses. Cleared afterwards, like any other sticky key —
            // and cleared even when the character has no function key, since
            // holding a layer that did nothing would be its own puzzle.
            defer { clearFunctionLayer() }
            if let number = functionKeyNumber(forCharacter: character) {
                if let bytes = KeyEncoder.bytes(for: .key(.function(number)),
                                                armedModifiers: controller.armedModifiers,
                                                applicationCursor: controller.applicationCursor) {
                    controller.send(bytes[...])
                }
                clearArmedModifiers()
            }

        case .character, .key, .chord:
            // The character/key/chord dispatch and the shift-before-encoding
            // rule all live in `KeyEncoder.bytes(for:armedModifiers:applicationCursor:)`
            // now — see its doc comment. It returns `nil` only for
            // `.modifier`/`.command`/`.blank`, none of which reaches this branch.
            if let bytes = KeyEncoder.bytes(for: value,
                                            armedModifiers: controller.armedModifiers,
                                            applicationCursor: controller.applicationCursor) {
                controller.send(bytes[...])
            }
            clearArmedModifiers()
        }
    }

    /// Whether the next key is a function key. Not a `KeyModifiers` bit: the
    /// encoder has no notion of fn, and giving it one would mean every escape
    /// sequence had to decide what to do with it.
    private var functionLayerArmed = false

    /// Drop the layer, unhighlight whichever key armed it, and put the digits
    /// back.
    private func clearFunctionLayer() {
        guard functionLayerArmed else { return }
        functionLayerArmed = false
        for view in keyViews where view.cap.primary == .functionLayer {
            view.setArmed(false)
        }
        applyFunctionLayer()
    }

    /// Tell every key whether the function layer is armed, so the ones fn
    /// changes say what they will do.
    private func applyFunctionLayer() {
        for view in keyViews {
            view.setFunctionLayer(functionLayerArmed)
        }
    }

    private func clearArmedModifiers() {
        controller?.armedModifiers = []
    }

    private func applyArmed(_ armed: KeyModifiers) {
        let shifted = armed.contains(.shift)
        for view in keyViews {
            // Every key redraws for shift, the way the system keyboard does:
            // the letters go upper case and the symbols show what they will
            // actually produce. Arming shift and then reading `,` on a key that
            // is about to send `<` is the keyboard lying about itself.
            view.setShifted(shifted)
            guard case .modifier(let modifiers) = view.cap.primary else { continue }
            view.setArmed(armed.contains(modifiers))
        }
    }

    // MARK: UIInputViewAudioFeedback

    // `KeyCapView` calls `UIDevice.current.playInputClick()` on touch-down,
    // which is a documented no-op unless something in the responder chain
    // conforms to this protocol with `enableInputClicksWhenVisible` returning
    // true. This view is the input view hosting the keys, so it's the one
    // that must conform — without it every keypress is silent.
    var enableInputClicksWhenVisible: Bool { true }
}
#endif
