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
    /// Where the touch began, in this view's coordinates — the drag distance
    /// is measured from here, not from one tracking callback to the next.
    private var dragOrigin: CGPoint = .zero

    init(cap: KeyCap, delegate: KeyCapViewDelegate) {
        self.cap = cap
        self.delegate = delegate
        super.init(frame: .zero)
        buildUI()
        configureAccessibility()
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

    // MARK: Accessibility

    /// VoiceOver has different needs than the glyph on the key: a bare "⌫"
    /// or "⇥" is spoken poorly or not at all, and a symbol reached only by
    /// dragging is otherwise invisible to VoiceOver, which cannot see the
    /// small secondary label's position as a hint. So this is a parallel
    /// vocabulary, not a reuse of `label(for:)`.
    private func configureAccessibility() {
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        accessibilityLabel = Self.accessibilityLabel(for: cap)
    }

    private static func accessibilityLabel(for cap: KeyCap) -> String {
        let primary = accessibilityLabel(for: cap.primary)
        guard let secondary = cap.secondary else { return primary }
        return "\(primary), drag up for \(accessibilityLabel(for: secondary))"
    }

    private static func accessibilityLabel(for value: KeyCap.Value) -> String {
        switch value {
        case .character(let c):        return c == " " ? "space" : String(c)
        case .key(let key):            return accessibilityLabel(for: key)
        case .modifier(let modifiers): return accessibilityLabel(for: modifiers)
        case .command(let command):
            switch command {
            case .dismissKeyboard: return "dismiss keyboard"
            case .closeTab:        return "close tab"
            }
        }
    }

    private static func accessibilityLabel(for key: TerminalKey) -> String {
        switch key {
        case .escape:      return "escape"
        case .tab:         return "tab"
        case .return:      return "return"
        case .backspace:   return "backspace"
        case .delete:      return "delete"
        case .up:          return "up arrow"
        case .down:        return "down arrow"
        case .left:        return "left arrow"
        case .right:       return "right arrow"
        case .home:        return "home"
        case .end:         return "end"
        case .pageUp:      return "page up"
        case .pageDown:    return "page down"
        case .function(let n): return "F\(n)"
        }
    }

    private static func accessibilityLabel(for modifiers: KeyModifiers) -> String {
        if modifiers.contains(.control) { return "control" }
        if modifiers.contains(.option)  { return "option" }
        if modifiers.contains(.shift)   { return "shift" }
        return "modifier"
    }

    // MARK: Touch handling

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        didDrag = false
        dragOrigin = touch.location(in: self)
        alpha = 0.6
        UIDevice.current.playInputClick()
        if cap.repeats { startRepeating() }
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard cap.secondary != nil else { return true }
        // Cumulative from touch-down, not from the previous callback — UIKit
        // delivers touchesMoved at 60-120Hz, so a slow drag arrives as many
        // sub-threshold deltas and `previousLocation` would never trip.
        // Once past the threshold this stays true for the rest of the touch:
        // a finger that overshoots and drifts back down still commits.
        let rise = dragOrigin.y - touch.location(in: self).y
        if rise > Self.dragThreshold, !didDrag {
            didDrag = true
            // A key that both repeats and carries a secondary (↑ repeating
            // to move the cursor, but also reaching Page Up on a drag) should
            // stop repeating the primary the moment the drag commits to the
            // secondary instead of continuing to fire the wrong one — see
            // `endTracking`, which delivers the secondary regardless of
            // `cap.repeats` for exactly this reason.
            stopRepeating()
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        alpha = 1
        stopRepeating()
        if didDrag, let secondary = cap.secondary {
            // Checked before `cap.repeats`: a repeating key that also carries
            // a secondary (see `continueTracking`) must still deliver it on a
            // committed drag, or that secondary would be permanently
            // unreachable on every such key.
            delegate?.keyCapView(self, didProduce: secondary)
            return
        }
        // A repeating key already fired on touch-down and on every tick;
        // firing again here would emit one extra character per press.
        guard !cap.repeats else { return }
        delegate?.keyCapView(self, didProduce: cap.primary)
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
