import AppKit
import RiftCore

/// The radius of each corner of a rectangle.
public struct RiftCornerRadii: Hashable, Sendable {
	public var topLeft: CGFloat
	public var topRight: CGFloat
	public var bottomLeft: CGFloat
	public var bottomRight: CGFloat

	public init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
		self.topLeft = topLeft
		self.topRight = topRight
		self.bottomLeft = bottomLeft
		self.bottomRight = bottomRight
	}

	public init(_ all: CGFloat) {
		self.init(topLeft: all, topRight: all, bottomLeft: all, bottomRight: all)
	}

	/// Each radius reduced by `amount` (never below zero).
	public func inset(by amount: CGFloat) -> Self {
		Self(
			topLeft: max(0, topLeft - amount), topRight: max(0, topRight - amount),
			bottomLeft: max(0, bottomLeft - amount), bottomRight: max(0, bottomRight - amount))
	}

	/// A rounded rectangle path with these corners, in a y-down space.
	public func path(in rect: CGRect) -> CGPath {
		let path = CGMutablePath()
		let limit = min(rect.width, rect.height) / 2
		let tl = min(topLeft, limit)
		let tr = min(topRight, limit)
		let bl = min(bottomLeft, limit)
		let br = min(bottomRight, limit)
		path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
		path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
		path.addArc(
			tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
			tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
		path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
		path.addArc(
			tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
			tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
		path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
		path.addArc(
			tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
			tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
		path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
		path.addArc(
			tangent1End: CGPoint(x: rect.minX, y: rect.minY),
			tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
		path.closeSubpath()
		return path
	}
}

/// Draws the focus ring: a stroke (solid or gradient) with its own radius per corner. Never
/// intercepts the mouse.
final class RiftFocusBorderView: RiftFlippedView {
	var isFocused = false { didSet { updateVisibility() } }
	var isEnabled = true { didSet { updateVisibility() } }
	var color: NSColor? { didSet { applyColors() } }
	/// Gradient stops; `nil` strokes with `color`.
	var gradientColors: [NSColor]? { didSet { applyColors() } }
	/// Degrees, measured clockwise from the +x axis with y pointing down.
	var gradientAngle: Double = 135 { didSet { applyGeometry() } }
	var lineWidth: CGFloat = 2 { didSet { applyGeometry() } }
	var cornerRadii = RiftCornerRadii(0) {
		didSet { if cornerRadii != oldValue { applyGeometry() } }
	}
	/// A single radius for all corners.
	var cornerRadius: CGFloat {
		get { cornerRadii.topLeft }
		set { cornerRadii = RiftCornerRadii(newValue) }
	}

	private let gradient = CAGradientLayer()
	private let strokeMask = CAShapeLayer()

	override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		strokeMask.fillColor = nil
		strokeMask.strokeColor = NSColor.black.cgColor
		gradient.mask = strokeMask
		layer?.addSublayer(gradient)
		updateVisibility()
		applyColors()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		applyGeometry()
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		applyColors()
	}

	private func updateVisibility() {
		gradient.isHidden = !(isEnabled && isFocused && lineWidth > 0)
	}

	private func applyColors() {
		let base = color ?? .controlAccentColor
		let stops = gradientColors ?? [base, base]
		var cg: [CGColor] = []
		effectiveAppearance.performAsCurrentDrawingAppearance { cg = stops.map(\.cgColor) }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		gradient.colors = cg.count == 1 ? [cg[0], cg[0]] : cg
		CATransaction.commit()
	}

	private func applyGeometry() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }
		gradient.frame = bounds
		strokeMask.frame = bounds
		strokeMask.lineWidth = lineWidth
		let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
		strokeMask.path =
			rect.width > 0 && rect.height > 0
			? cornerRadii.inset(by: lineWidth / 2).path(in: rect) : nil
		let radians = gradientAngle * .pi / 180
		let dx = cos(radians) / 2
		let dy = sin(radians) / 2
		// The layer of a flipped view is flipped too, so unit y grows downward here.
		gradient.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
		gradient.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
		updateVisibility()
	}
}
