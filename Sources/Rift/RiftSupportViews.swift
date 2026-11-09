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

	var headerHeight: CGFloat = 24 { didSet { layoutParts() } }
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
	var isFocused = false { didSet { updateFocusAppearance() } }

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

	private func layoutParts() {
		let h = showsHeader ? min(headerHeight, bounds.height) : 0
		header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
		contentClip.frame = CGRect(
			x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
		// Without a header bar the strip floats over the top of the content.
		strip.frame = CGRect(
			x: 0, y: 0, width: bounds.width, height: min(headerHeight, bounds.height))
		border.frame = bounds
	}

	private func updateFocusAppearance() {
		border.isFocused = isFocused
		header.isFocused = isFocused
		contentClip.alphaValue = isFocused ? 1 : inactiveAlpha
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
		let side = max(28, x + 2)
		let height = titleField.intrinsicContentSize.height
		let width = max(0, bounds.width - side * 2)
		let centred = CGRect(x: side, y: (bounds.height - height) / 2, width: width, height: height)
		if width >= min(titleField.intrinsicContentSize.width, 80) {
			titleField.frame = centred
		} else {
			titleField.frame = CGRect(
				x: x + 2, y: centred.minY, width: max(0, bounds.width - x - 8), height: height)
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

/// Draws the focus ring. Never intercepts the mouse.
final class RiftFocusBorderView: RiftFlippedView {
	var isFocused = false { didSet { needsDisplay = true } }
	var isEnabled = true { didSet { needsDisplay = true } }
	var color: NSColor? { didSet { needsDisplay = true } }
	var lineWidth: CGFloat = 2 { didSet { needsDisplay = true } }
	var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override func draw(_ dirtyRect: NSRect) {
		guard isEnabled, isFocused, lineWidth > 0 else { return }
		let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
		let radius = max(0, cornerRadius - lineWidth / 2)
		let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
		path.lineWidth = lineWidth
		(color ?? .controlAccentColor).setStroke()
		path.stroke()
	}
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
