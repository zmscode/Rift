import AppKit
import RiftCore

/// A plain flipped view.
class RiftFlippedView: NSView {
	override var isFlipped: Bool { true }
}

/// Hosts one pane: an optional header, the content, and the focus border.
final class RiftPaneContainerView: RiftFlippedView {
	let header = RiftPaneHeaderView()
	let contentClip = RiftFlippedView()
	let strip = RiftPaneDragStripView()
	let border = RiftFocusBorderView()
	private(set) var contentView: NSView
	/// The pane's surface (background, glass, fills), behind the content.
	private(set) var surfaceView: NSView?
	/// The provider `surfaceView` came from, to tell whether it must be rebuilt.
	var surfaceSource: RiftPaneSurfaces?
	var hasCustomSurface = false

	func setSurfaceView(_ view: NSView?) {
		surfaceView?.removeFromSuperview()
		surfaceView = view
		guard let view else { return }
		view.frame = bounds
		view.autoresizingMask = [.width, .height]
		addSubview(view, positioned: .below, relativeTo: contentClip)
	}

	var headerHeight: CGFloat = 24 { didSet { layoutParts() } }
	/// Space kept above the content when there is no header bar.
	var headerlessTopInset: CGFloat = 0 { didSet { layoutParts() } }
	var showsHeader = true {
		didSet {
			header.isHidden = !showsHeader
			strip.isHidden = showsHeader
			layoutParts()
		}
	}
	var cornerRadius: CGFloat = 0 {
		didSet {
			layer?.cornerRadius = cornerRadius
			layer?.masksToBounds = cornerRadius > 0
			border.cornerRadius = cornerRadius
		}
	}
	var inactiveAlpha: CGFloat = 1 { didSet { updateFocusAppearance() } }
	var activeAlpha: CGFloat = 1 { didSet { updateFocusAppearance() } }
	var isFocused = false { didSet { updateFocusAppearance() } }

	/// The pane's opacity is the product of these: a pane being dragged, a layout motion (growth
	/// or a visibility fade), and a pop in or out.
	var dragAlpha: CGFloat = 1 { didSet { refreshAlpha() } }
	var motionAlpha: CGFloat = 1 { didSet { refreshAlpha() } }
	var popAlpha: CGFloat = 1 { didSet { refreshAlpha() } }
	private func refreshAlpha() {
		let alpha = dragAlpha * motionAlpha * popAlpha
		if alphaValue != alpha { alphaValue = alpha }
	}

	init(content: NSView) {
		contentView = content
		super.init(frame: .zero)
		wantsLayer = true
		autoresizesSubviews = true
		header.autoresizingMask = [.width]
		strip.autoresizingMask = [.width]
		strip.isHidden = true
		contentClip.autoresizingMask = [.width, .height]
		border.autoresizingMask = [.width, .height]
		addSubview(contentClip)
		addSubview(header)
		addSubview(strip)
		addSubview(border)
		install(content)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	private func install(_ content: NSView) {
		contentClip.wantsLayer = true
		content.removeFromSuperview()
		content.translatesAutoresizingMaskIntoConstraints = true
		content.autoresizingMask = [.width, .height]
		content.frame = contentClip.bounds
		contentClip.addSubview(content)
	}

	/// Removes the content so it can be adopted by another container.
	func detachContent() -> NSView {
		contentView.removeFromSuperview()
		return contentView
	}

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		layoutParts()
	}

	/// While set, the content keeps this pane size (top-left aligned, clipped) instead of following
	/// the container, so it reflows once rather than on every animation frame. A container
	/// (sidebar) animation's size wins over a layout motion's.
	var containerPinnedSize: CGSize? {
		didSet { if containerPinnedSize != oldValue { layoutParts() } }
	}
	var motionPinnedSize: CGSize? { didSet { if motionPinnedSize != oldValue { layoutParts() } } }
	var pinnedPaneSize: CGSize? { containerPinnedSize ?? motionPinnedSize }

	private func layoutParts() {
		let h =
			showsHeader ? min(headerHeight, bounds.height) : min(headerlessTopInset, bounds.height)
		header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
		contentClip.frame = CGRect(
			x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
		contentClip.layer?.masksToBounds = pinnedPaneSize != nil
		if let pinned = pinnedPaneSize {
			contentView.autoresizingMask = []
			contentView.frame = CGRect(
				x: 0, y: 0, width: pinned.width, height: max(0, pinned.height - h))
		} else {
			contentView.autoresizingMask = [.width, .height]
			contentView.frame = contentClip.bounds
		}
		// Without a header bar the strip floats over the top of the content.
		strip.frame = CGRect(
			x: 0, y: 0, width: bounds.width, height: min(headerHeight, bounds.height))
		border.frame = bounds
	}

	private func updateFocusAppearance() {
		border.isFocused = isFocused
		header.isFocused = isFocused
		contentClip.alphaValue = isFocused ? activeAlpha : inactiveAlpha
	}

	override func isAccessibilityElement() -> Bool { true }
	override func accessibilityRole() -> NSAccessibility.Role? { .group }
	override func accessibilityLabel() -> String? { header.title }
}

/// An invisible strip along the top of a pane, used when pane headers are off.
///
/// - The top-left corner (`handleWidth` wide, after `leadingInset`) drags the pane. A grip fades in
///   while the pointer is over it.
/// - When `movesWindow` is set (the pane sits at the top of a headless window), the rest of the
///   strip drags the window. Otherwise the rest of the strip lets the mouse through to the content.
final class RiftPaneDragStripView: RiftFlippedView {
	var handleWidth: CGFloat = 44 { didSet { if handleWidth != oldValue { needsLayout = true } } }
	var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { needsLayout = true } } }
	var movesWindow = false { didSet { if movesWindow != oldValue { needsLayout = true } } }
	var allowsPaneDrag = true { didSet { needsLayout = true } }
	var onHandleMouseDown: ((NSEvent) -> Void)?
	var onStripMouseDown: ((NSEvent) -> Void)?
	/// Called when the pointer enters or leaves a part of the strip that takes the mouse.
	var onPointerRegionChange: (() -> Void)?
	/// While set, the strip ignores the mouse so a replayed click reaches the content.
	var isReplayingClick = false

	private let grip = NSImageView()
	private var handleTrackingArea: NSTrackingArea?
	private var stripTrackingArea: NSTrackingArea?
	private var isHoveringHandle = false { didSet { updateGrip(animated: true) } }

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		grip.image = NSImage(
			systemSymbolName: "line.3.horizontal", accessibilityDescription: "Move Pane")
		grip.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
		grip.contentTintColor = .secondaryLabelColor
		grip.imageScaling = .scaleProportionallyDown
		grip.wantsLayer = true
		grip.layer?.cornerRadius = 5
		grip.alphaValue = 0
		addSubview(grip)
		setAccessibilityElement(false)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	/// The corner that drags the pane, in this view's coordinates.
	var handleRect: CGRect {
		guard allowsPaneDrag else { return .zero }
		let width = min(handleWidth, max(0, bounds.width - leadingInset))
		return CGRect(x: leadingInset, y: 0, width: width, height: bounds.height)
	}

	/// Whether this point (in this view's coordinates) is one the strip responds to.
	func handlesPoint(_ point: CGPoint) -> Bool {
		guard !isHiddenOrHasHiddenAncestor, bounds.contains(point) else { return false }
		return handleRect.contains(point) || movesWindow
	}

	override func layout() {
		super.layout()
		let size: CGFloat = 22
		let handle = handleRect
		grip.frame = CGRect(
			x: handle.minX + 6, y: ((bounds.height - size) / 2).rounded(), width: size, height: size
		)
		rebuildTrackingAreas()
		if let window {
			isHoveringHandle = handle.contains(
				convert(window.mouseLocationOutsideOfEventStream, from: nil))
		}
		updateGrip(animated: false)
	}

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		needsLayout = true
	}

	private func updateGrip(animated: Bool) {
		let alpha: CGFloat = isHoveringHandle && allowsPaneDrag ? 1 : 0
		grip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
		guard animated else {
			grip.alphaValue = alpha
			return
		}
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.12
			grip.animator().alphaValue = alpha
		}
	}

	// Only the handle (and, when it moves the window, the whole strip) take the mouse.
	override func hitTest(_ point: NSPoint) -> NSView? {
		let local = convert(point, from: superview)
		guard !isReplayingClick else { return nil }
		return handlesPoint(local) ? self : nil
	}

	override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		if handleRect.contains(point) {
			onHandleMouseDown?(event)
		} else if movesWindow {
			onStripMouseDown?(event)
		}
	}

	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		rebuildTrackingAreas()
	}

	/// Enter/exit tracking (unlike mouse-moved events) works even when the app isn't active, so
	/// the window can be locked before the first click lands. Rebuilt whenever the layout changes.
	private func rebuildTrackingAreas() {
		for area in [handleTrackingArea, stripTrackingArea].compactMap({ $0 }) {
			removeTrackingArea(area)
		}
		handleTrackingArea = nil
		stripTrackingArea = nil
		let handle = handleRect
		if !handle.isEmpty {
			let area = NSTrackingArea(
				rect: handle, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
				owner: self, userInfo: nil)
			addTrackingArea(area)
			handleTrackingArea = area
		}
		if movesWindow, !bounds.isEmpty {
			let area = NSTrackingArea(
				rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self,
				userInfo: nil)
			addTrackingArea(area)
			stripTrackingArea = area
		}
	}

	override func mouseEntered(with event: NSEvent) {
		if event.trackingArea === handleTrackingArea { isHoveringHandle = true }
		onPointerRegionChange?()
	}

	override func mouseExited(with event: NSEvent) {
		if event.trackingArea === handleTrackingArea { isHoveringHandle = false }
		onPointerRegionChange?()
	}

	override func cursorUpdate(with event: NSEvent) {
		if event.trackingArea === handleTrackingArea {
			NSCursor.openHand.set()
		} else {
			super.cursorUpdate(with: event)
		}
	}

	override func viewDidHide() {
		super.viewDidHide()
		isHoveringHandle = false
	}
}

/// A small grip that starts a pane drag when the header itself moves the window.
final class RiftHeaderGripView: NSImageView {
	var onMouseDown: ((NSEvent) -> Void)?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		image = NSImage(
			systemSymbolName: "line.3.horizontal", accessibilityDescription: "Move Pane")
		symbolConfiguration = .init(pointSize: 10, weight: .semibold)
		contentTintColor = .tertiaryLabelColor
		imageScaling = .scaleProportionallyDown
		toolTip = "Drag to move this pane"
		setAccessibilityLabel("Move Pane")
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// The strip at the top of a pane: title, close button, and the handle for dragging the pane.
final class RiftPaneHeaderView: RiftFlippedView {
	private let titleField = NSTextField(labelWithString: "")
	private let closeButton = NSButton()
	private let grip = RiftHeaderGripView()

	var title: String {
		get { titleField.stringValue }
		set {
			titleField.stringValue = newValue
			titleField.toolTip = newValue
		}
	}
	var showsCloseButton = true { didSet { updateVisibility() } }
	/// Show the grip for moving the pane (used when dragging the header moves the window).
	var showsGrip = false { didSet { updateVisibility() } }
	/// A bare header is an empty drag strip: no title or buttons.
	var isBare = false {
		didSet {
			updateVisibility()
			needsDisplay = true
		}
	}
	/// Space kept clear at the leading edge, for the window's buttons.
	var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { needsLayout = true } } }
	/// Room kept clear at the trailing edge (for example for a sidebar's toggle button).
	var trailingInset: CGFloat = 0 {
		didSet { if trailingInset != oldValue { needsLayout = true } }
	}
	var isFocused = false {
		didSet {
			titleField.textColor = isFocused ? .labelColor : .secondaryLabelColor
			needsDisplay = true
		}
	}
	var onMouseDown: ((NSEvent) -> Void)?
	/// Called when the pointer enters or leaves the header.
	var onPointerRegionChange: (() -> Void)?
	private var headerTrackingArea: NSTrackingArea?
	var onGripMouseDown: ((NSEvent) -> Void)? {
		get { grip.onMouseDown }
		set { grip.onMouseDown = newValue }
	}
	var onClose: (() -> Void)?

	private func updateVisibility() {
		titleField.isHidden = isBare
		closeButton.isHidden = isBare || !showsCloseButton
		grip.isHidden = isBare || !showsGrip
		needsLayout = true
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		titleField.font = .systemFont(ofSize: 11, weight: .medium)
		titleField.textColor = .secondaryLabelColor
		titleField.lineBreakMode = .byTruncatingTail
		titleField.alignment = .center
		addSubview(titleField)

		closeButton.image = NSImage(
			systemSymbolName: "xmark", accessibilityDescription: "Close Pane")
		closeButton.isBordered = false
		closeButton.imagePosition = .imageOnly
		closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
		closeButton.contentTintColor = .secondaryLabelColor
		closeButton.target = self
		closeButton.action = #selector(closeClicked)
		closeButton.setAccessibilityLabel("Close Pane")
		addSubview(closeButton)
		addSubview(grip)
		updateVisibility()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	@objc private func closeClicked() { onClose?() }

	override func layout() {
		super.layout()
		let size: CGFloat = 16
		let y = ((bounds.height - size) / 2).rounded()
		var x = leadingInset + 6
		if !closeButton.isHidden {
			closeButton.frame = CGRect(x: x, y: y, width: size, height: size)
			x += size + 4
		}
		if !grip.isHidden {
			grip.frame = CGRect(x: x, y: y, width: size, height: size)
			x += size + 4
		}
		// Keep the title centred in the header when there's room, clear of the leading controls.
		let side = max(28, x + 2, trailingInset + 8)
		let height = titleField.intrinsicContentSize.height
		let width = max(0, bounds.width - side * 2)
		let centred = CGRect(x: side, y: (bounds.height - height) / 2, width: width, height: height)
		if width >= min(titleField.intrinsicContentSize.width, 80) {
			titleField.frame = centred
		} else {
			titleField.frame = CGRect(
				x: x + 2, y: centred.minY, width: max(0, bounds.width - x - 8 - trailingInset),
				height: height)
		}
	}

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		needsLayout = true
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.windowBackgroundColor.setFill()
		bounds.fill()
		if isFocused {
			NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
			bounds.fill(using: .sourceOver)
		}
		NSColor.separatorColor.setFill()
		CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
	}

	// Clicks on the title count as clicks on the header (so the title drags the pane).
	override func hitTest(_ point: NSPoint) -> NSView? {
		let hit = super.hitTest(point)
		return hit === titleField ? self : hit
	}

	override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let headerTrackingArea { removeTrackingArea(headerTrackingArea) }
		let area = NSTrackingArea(
			rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
			owner: self, userInfo: nil)
		addTrackingArea(area)
		headerTrackingArea = area
	}

	override func mouseEntered(with event: NSEvent) { onPointerRegionChange?() }
	override func mouseExited(with event: NSEvent) { onPointerRegionChange?() }
}

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

/// Shows where a dragged pane will land: a translucent accent fill with a solid 2pt outline.
final class RiftDropIndicatorView: RiftFlippedView {
	var color: NSColor? { didSet { needsDisplay = true } }
	var cornerRadius: CGFloat = 8 { didSet { needsDisplay = true } }

	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override func draw(_ dirtyRect: NSRect) {
		let accent = color ?? .controlAccentColor
		let fill = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
		accent.withAlphaComponent(0.25).setFill()
		fill.fill()
		let inner = bounds.insetBy(dx: 1, dy: 1)
		guard inner.width > 0, inner.height > 0 else { return }
		let radius = max(0, cornerRadius - 1)
		let stroke = NSBezierPath(roundedRect: inner, xRadius: radius, yRadius: radius)
		stroke.lineWidth = 2
		accent.setStroke()
		stroke.stroke()
	}
}

/// A borderless child window that shows the drop highlight above everything in its parent,
/// including glass and other views' layers.
final class RiftDropOverlayWindow: NSPanel {
	let indicator = RiftDropIndicatorView()

	init() {
		super.init(
			contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
			defer: true)
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		ignoresMouseEvents = true
		isReleasedWhenClosed = false
		collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
		indicator.autoresizingMask = [.width, .height]
		contentView = indicator
	}

	/// Shows the highlight over `screenRect` above `parent`, or hides it.
	func show(_ screenRect: CGRect?, above parent: NSWindow?) {
		guard let screenRect, let parent else {
			self.parent?.removeChildWindow(self)
			orderOut(nil)
			return
		}
		if self.parent !== parent {
			self.parent?.removeChildWindow(self)
			parent.addChildWindow(self, ordered: .above)
		}
		setFrame(screenRect, display: true)
		indicator.needsDisplay = true
		orderFront(nil)
	}
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

/// Weak references to every live Rift view, so a pane drag can find drop targets in other windows.
@MainActor
enum RiftViewRegistry {
	private final class WeakBox {
		weak var view: NSView?
		init(_ view: NSView) { self.view = view }
	}

	private static var boxes: [WeakBox] = []

	static func register(_ view: NSView) {
		boxes.removeAll { $0.view == nil || $0.view === view }
		boxes.append(WeakBox(view))
	}

	static func unregister(_ view: NSView) {
		boxes.removeAll { $0.view == nil || $0.view === view }
	}

	static func views<V: NSView>(of type: V.Type) -> [V] {
		boxes.compactMap { $0.view as? V }
	}
}
