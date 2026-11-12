import AppKit
import RiftCore

/// Draws divider lines as layers, so they can use a blend mode and fade one by one.
final class RiftDividerLinesView: NSView {
	private var lineLayers: [CALayer] = []
	private let coverMask = CAShapeLayer()

	override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		coverMask.fillRule = .evenOdd
		coverMask.fillColor = NSColor.black.cgColor
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override var isFlipped: Bool { true }
	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	/// `lines` are in this view's coordinates; each has its own opacity (0…1).
	func show(
		_ lines: [(rect: CGRect, opacity: CGFloat)], color: NSColor, blendMode: RiftDividerBlendMode
	) {
		guard let layer else { return }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		while lineLayers.count < lines.count {
			let line = CALayer()
			layer.addSublayer(line)
			lineLayers.append(line)
		}
		while lineLayers.count > lines.count { lineLayers.removeLast().removeFromSuperlayer() }
		var cgColor: CGColor?
		effectiveAppearance.performAsCurrentDrawingAppearance { cgColor = color.cgColor }
		let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		for (line, item) in zip(lineLayers, lines) {
			line.frame = item.rect
			line.opacity = Float(min(max(item.opacity, 0), 1))
			line.backgroundColor = cgColor
			line.compositingFilter = blendMode.compositingFilter(isDark: dark)
		}
		CATransaction.commit()
	}

	/// Hides the lines inside `rect` but outside its rounded inner edge `inset` points in: the band
	/// a focus border covers, including its corners. `nil` shows every line.
	func cover(_ rect: CGRect?, radii: RiftCornerRadii, inset: CGFloat) {
		guard let layer else { return }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }
		guard let rect, rect.width > 0, rect.height > 0 else {
			layer.mask = nil
			return
		}
		let path = CGMutablePath()
		path.addRect(bounds)
		path.addRect(rect)
		let inner = rect.insetBy(dx: inset, dy: inset)
		if inner.width > 0, inner.height > 0 {
			path.addPath(radii.inset(by: inset).path(in: inner))
		}
		coverMask.frame = bounds
		coverMask.path = path
		layer.mask = coverMask
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		(superview as? RiftDividerLinesHost)?.refreshDividerLines()
	}
}

@MainActor
protocol RiftDividerLinesHost: AnyObject {
	func refreshDividerLines()
}

/// Exposes one divider to VoiceOver as an adjustable splitter.
final class RiftDividerAccessibilityElement: NSAccessibilityElement {
	var splitID = UUID()
	var axis: RiftAxis = .horizontal
	var position: Double = 0.5
	var label = "Divider"
	var adjust: ((_ step: Double) -> Bool)?

	override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
	override func accessibilityLabel() -> String? { label }
	override func accessibilityValue() -> Any? { NSNumber(value: position) }
	override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
	override func accessibilityMaxValue() -> Any? { NSNumber(value: 1) }
	override func accessibilityValueDescription() -> String? {
		"\(Int((position * 100).rounded())) percent"
	}
	// A horizontal split has a vertical divider line.
	override func accessibilityOrientation() -> NSAccessibilityOrientation {
		axis == .horizontal ? .vertical : .horizontal
	}
	override func accessibilityPerformIncrement() -> Bool { adjust?(1) ?? false }
	override func accessibilityPerformDecrement() -> Bool { adjust?(-1) ?? false }
}
