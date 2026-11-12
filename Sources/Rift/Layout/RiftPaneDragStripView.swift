import AppKit
import RiftCore

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
	/// The menu shown on a right-click on the strip.
	var menuProvider: (() -> NSMenu?)?
	override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
	var onHandleMouseDown: ((NSEvent) -> Void)?
	var onStripMouseDown: ((NSEvent) -> Void)?
	/// Called when the pointer enters or leaves a part of the strip that takes the mouse.
	var onPointerRegionChange: (() -> Void)?
	/// While set, the strip ignores the mouse so a replayed click reaches the content.
	var isReplayingClick = false

	private let grip = NSImageView()
	private var handleTrackingArea: NSTrackingArea?
	private var stripTrackingArea: NSTrackingArea?
	private var isHoveringHandle = false {
		didSet { if isHoveringHandle != oldValue { updateGrip(animated: true) } }
	}

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
		updateGripColor()
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
		guard !isHidden else { return }
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

	private func updateGripColor() {
		effectiveAppearance.performAsCurrentDrawingAppearance {
			grip.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
		}
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		updateGripColor()
	}

	private func updateGrip(animated: Bool) {
		let alpha: CGFloat = isHoveringHandle && allowsPaneDrag ? 1 : 0
		guard animated else {
			if grip.alphaValue != alpha { grip.alphaValue = alpha }
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
		if handlesPoint(local) { return self }
		// A click that opens the pane's menu lands anywhere along the strip, on every pane (the
		// header region is the pane's own, wherever the pane sits in the window).
		if menuProvider != nil, !isHiddenOrHasHiddenAncestor, bounds.contains(local),
			let event = NSApp.currentEvent, Self.opensMenu(event)
		{
			return self
		}
		return nil
	}

	/// A right-click, or a Control-click.
	private static func opensMenu(_ event: NSEvent) -> Bool {
		event.type == .rightMouseDown
			|| (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
	}

	override func mouseDown(with event: NSEvent) {
		if Self.opensMenu(event), let menu = menuProvider?() {
			NSMenu.popUpContextMenu(menu, with: event, for: self)
			return
		}
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
		let handle = handleRect
		let strip = movesWindow ? bounds : .zero
		// Nothing to do when both areas already cover the right rectangles (most resize frames
		// only change the strip's width, and most strips only have the handle).
		if (handleTrackingArea?.rect ?? .zero) == handle, (stripTrackingArea?.rect ?? .zero) == strip
		{
			return
		}
		for area in [handleTrackingArea, stripTrackingArea].compactMap({ $0 }) {
			removeTrackingArea(area)
		}
		handleTrackingArea = nil
		stripTrackingArea = nil
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
