import AppKit

// CALayer stores fixed CGColors. Resolve semantic colours in the view's appearance
// whenever it draws, including after moving into a window or switching appearance.
private func updateSurface(_ view: NSView, fill: NSColor?, border: NSColor?) {
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.layer?.backgroundColor = fill?.cgColor
        view.layer?.borderColor = border?.cgColor
    }
}

class SurfaceView: NSView {
    var surfaceColor: NSColor? { didSet { needsDisplay = true } }
    var surfaceBorderColor: NSColor? { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { updateSurface(self, fill: surfaceColor, border: surfaceBorderColor) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class SurfaceStackView: NSStackView {
    var surfaceColor: NSColor? { didSet { needsDisplay = true } }
    var surfaceBorderColor: NSColor? { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { updateSurface(self, fill: surfaceColor, border: surfaceBorderColor) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
