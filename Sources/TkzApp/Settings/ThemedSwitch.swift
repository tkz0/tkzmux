// ThemedSwitch.swift — the 30 × 18 pill switch from design 7a.
//
// Not an `NSSwitch`: that control follows the system accent and takes no tint, so beside the
// accent-coloured buttons the rest of the app draws (`RebaseSheetView`) it would be the one
// control wearing another colour. An `NSView` rather than a cell-less `NSControl` — `isEnabled`
// and friends on `NSControl` route through a cell this view does not have. What it keeps from
// `NSSwitch` is the accessibility contract: a check box with the switch subrole, pressable, with a
// 0/1 value, and Space toggles it from the keyboard.

import AppKit
import TkzCore

@MainActor
final class ThemedSwitch: NSView {

    enum Metrics {
        static let width = CGFloat(DesignTokens.Metrics.ThemedSwitch.width.value)
        static let height = CGFloat(DesignTokens.Metrics.ThemedSwitch.height.value)
        static let knob = CGFloat(DesignTokens.Metrics.ThemedSwitch.knob.value)
        static let inset = CGFloat(DesignTokens.Metrics.ThemedSwitch.inset.value)
    }

    /// The user flipped it (a click or Space). Not called for programmatic `isOn` writes.
    var onToggle: ((Bool) -> Void)?

    var isOn: Bool = false {
        didSet {
            guard isOn != oldValue else { return }
            layoutKnob(animated: true)
            applyColors()
        }
    }

    var isEnabled: Bool = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4 }
    }

    private var theme: Theme
    private let track = CALayer()
    private let knob = CALayer()

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        track.cornerRadius = Metrics.height / 2
        track.frame = bounds
        knob.cornerRadius = Metrics.knob / 2
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowOffset = CGSize(width: 0, height: -1)
        knob.shadowRadius = 1
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        applyColors()
        layoutKnob(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used; tkzmux builds views in code") }

    override var intrinsicContentSize: NSSize { NSSize(width: Metrics.width, height: Metrics.height) }

    func setTheme(_ theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        applyColors()
    }

    // MARK: Drawing

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let accent = theme.accent
        let off = theme.foreground
        track.backgroundColor = isOn
            ? accent.cgColor
            : RGB(r: off.r, g: off.g, b: off.b, a: 0.18).cgColor
        knob.backgroundColor = NSColor.white.cgColor
        CATransaction.commit()
    }

    private func layoutKnob(animated: Bool) {
        let x = isOn ? Metrics.width - Metrics.inset - Metrics.knob : Metrics.inset
        let frame = CGRect(x: x, y: Metrics.inset, width: Metrics.knob, height: Metrics.knob)
        if animated {
            let animation = CABasicAnimation(keyPath: "position")
            animation.fromValue = NSValue(point: knob.position)
            animation.duration = 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            knob.add(animation, forKey: "position")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.frame = frame
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        CATransaction.commit()
        layoutKnob(animated: false)
    }

    // MARK: Input

    private func toggleFromUser() {
        guard isEnabled else { return }
        isOn.toggle()
        onToggle?(isOn)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        toggleFromUser()
    }

    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r":
            toggleFromUser()
        default:
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.height / 2, yRadius: Metrics.height / 2).fill()
    }

    // MARK: Accessibility

    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggleFromUser()
        return true
    }

    override func isAccessibilityEnabled() -> Bool { isEnabled }

    // MARK: Test access

    /// What a click does, without an event.
    func toggleForTesting() { toggleFromUser() }
}
