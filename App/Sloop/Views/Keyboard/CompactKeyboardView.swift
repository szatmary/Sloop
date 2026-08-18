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
final class CompactKeyboardView: UIInputView, KeyCapViewDelegate, UIInputViewAudioFeedback {
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
            case .closeTab:
                // No layout table places a closeTab cap today, so this case
                // is currently unreachable from this keyboard. Closing a tab
                // is reached through TerminalPane's own affordance, not here;
                // this stays a deliberate no-op rather than an oversight.
                break
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

    // MARK: UIInputViewAudioFeedback

    // `KeyCapView` calls `UIDevice.current.playInputClick()` on touch-down,
    // which is a documented no-op unless something in the responder chain
    // conforms to this protocol with `enableInputClicksWhenVisible == true`.
    // This view is the input view hosting the keys, so it's the one that
    // must conform — without it every keypress is silent.
    var enableInputClicksWhenVisible: Bool { true }
}
#endif
