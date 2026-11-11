import AppKit
import RiftCore

/// One floating layer: a window-like card with its own `RiftView` of panes, a shadow that lifts
/// while it moves, a strip along its top that moves it, and edges that resize it.
@MainActor
final class RiftFloatingLayerView<PaneID: Hashable & Sendable>: NSView {
	let id: UUID
	let content: RiftView<PaneID>
	weak var host: RiftView<PaneID>?

	private let shadowLayer = CALayer() 
	private let clip = NSView()
	private let moveStrip = RiftFloatingMoveStrip()
	private var resizeHandles: [RiftFloatingResizeHandle] = []
	private(set) var isActive = false

	/// The corner radius (the window surface's).
	var cornerRadius: CGFloat = 12 { didSet { needsLayout = true } }

	init(id: UUID, layout: RiftLayout<PaneID>, host: RiftView<PaneID>) {
		self.id = id
		self.host = host
		var configuration = host.configuration
		configuration.windowStyle = .standard
		if configuration.windowSurface == nil {
			configuration.windowSurface = .modern(.comfortable)
		}
		content = RiftView(
			layout: layout, configuration: configuration, makePaneView: host.makePaneView)
		super.init(frame: .zero)
		wantsLayer = true
		layer?.masksToBounds = false
		shadowLayer.shadowColor = NSColor.black.cgColor
		layer?.addSublayer(shadowLayer)
		clip.wantsLayer = true
		clip.layer?.masksToBounds = true
		clip.layer?.cornerCurve = .continuous
		addSubview(clip)
		content.groupIdentifier = host.groupIdentifier
		content.paneTitle = host.paneTitle
		content.makeDragPreview = host.makeDragPreview
		content.paneActivity = host.paneActivity
		clip.addSubview(content)
		moveStrip.onDrag = { [weak self] phase, delta in
			self?.host?.floatingMove(self, phase: phase, delta: delta)
		}
		moveStrip.onDoubleClick = { [weak self] in
			guard let self else { return }
			self.host?.dockFloatingLayer(self.id)
		}
		addSubview(moveStrip)
		for edges: RiftResizeEdges in [
			.left, .right, .top, .bottom, [.left, .top], [.right, .top], [.left, .bottom],
			[.right, .bottom],
		] {
			let handle = RiftFloatingResizeHandle(edges: edges)
			handle.onDrag = { [weak self] phase, delta in
				self?.host?.floatingResize(self, edges: edges, phase: phase, delta: delta)
			}
			resizeHandles.append(handle)
			addSubview(handle)
		}
		setActive(false, animated: false)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override var isFlipped: Bool { true }

	override func layout() {
		super.layout()
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		clip.frame = bounds
		clip.layer?.cornerRadius = cornerRadius
		content.frame = clip.bounds
		shadowLayer.frame = bounds
		shadowLayer.shadowPath = CGPath(
			roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
			transform: nil)
		CATransaction.commit()
		// The top strip moves the layer, except where pane headers keep their drag handle.
		let strip = RiftFloatingMetrics.stripHeight
		moveStrip.frame = CGRect(x: 44, y: 0, width: max(0, bounds.width - 44), height: strip)
		let e = RiftFloatingMetrics.edgeThickness
		let c = RiftFloatingMetrics.cornerSize
		for handle in resizeHandles {
			let edges = handle.edges
			let w = bounds.width
			let h = bounds.height
			switch edges {
			case .left: handle.frame = CGRect(x: -e / 2, y: c, width: e, height: max(0, h - 2 * c))
			case .right:
				handle.frame = CGRect(x: w - e / 2, y: c, width: e, height: max(0, h - 2 * c))
			case .top: handle.frame = CGRect(x: c, y: -e / 2, width: max(0, w - 2 * c), height: e)
			case .bottom:
				handle.frame = CGRect(x: c, y: h - e / 2, width: max(0, w - 2 * c), height: e)
			case [.left, .top]: handle.frame = CGRect(x: -e / 2, y: -e / 2, width: c, height: c)
			case [.right, .top]:
				handle.frame = CGRect(x: w - c + e / 2, y: -e / 2, width: c, height: c)
			case [.left, .bottom]:
				handle.frame = CGRect(x: -e / 2, y: h - c + e / 2, width: c, height: c)
			default: handle.frame = CGRect(x: w - c + e / 2, y: h - c + e / 2, width: c, height: c)
			}
		}
	}

	/// The resting shadow, or the lifted one while the layer moves or resizes.
	func setActive(_ active: Bool, animated: Bool) {
		isActive = active
		let shadow = active ? RiftFloatingShadow.active : .resting
		let apply = {
			self.shadowLayer.shadowOpacity = shadow.opacity
			self.shadowLayer.shadowRadius = shadow.radius
			self.shadowLayer.shadowOffset = CGSize(width: 0, height: shadow.y)
		}
		if animated {
			CATransaction.begin()
			CATransaction.setAnimationDuration(0.2)
			apply()
			CATransaction.commit()
		} else {
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			apply()
			CATransaction.commit()
		}
	}

}

/// Sizes of a floating layer's handles.
enum RiftFloatingMetrics {
	/// The strip along the top that moves the layer (pane headers are 28pt).
	static let stripHeight: CGFloat = 28
	static let edgeThickness: CGFloat = 8
	static let cornerSize: CGFloat = 16
}

enum RiftFloatingDragPhase { case began, changed, ended }

/// Moves a floating layer: drag to move, double-click to dock it back into the layout.
final class RiftFloatingMoveStrip: NSView {
	var onDrag: ((RiftFloatingDragPhase, CGSize) -> Void)?
	var onDoubleClick: (() -> Void)?
	private var start: CGPoint?

	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	override func mouseDown(with event: NSEvent) {
		if event.clickCount == 2 {
			onDoubleClick?()
			return
		}
		start = event.locationInWindow
		onDrag?(.began, .zero)
	}

	override func mouseDragged(with event: NSEvent) {
		guard let start else { return }
		let p = event.locationInWindow
		// Window coordinates have y up; the layout's grow down.
		onDrag?(.changed, CGSize(width: p.x - start.x, height: start.y - p.y))
	}

	override func mouseUp(with event: NSEvent) {
		guard start != nil else { return }
		start = nil
		onDrag?(.ended, .zero)
	}
}

/// One resize edge or corner of a floating layer.
final class RiftFloatingResizeHandle: NSView {
	let edges: RiftResizeEdges
	var onDrag: ((RiftFloatingDragPhase, CGSize) -> Void)?
	private var start: CGPoint?

	init(edges: RiftResizeEdges) {
		self.edges = edges
		super.init(frame: .zero)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	override func resetCursorRects() {
		addCursorRect(bounds, cursor: cursor)
	}

	private var cursor: NSCursor {
		if #available(macOS 15.0, *) {
			let position: NSCursor.FrameResizePosition
			switch edges {
			case .left: position = .left
			case .right: position = .right
			case .top: position = .top
			case .bottom: position = .bottom
			case [.left, .top]: position = .topLeft
			case [.right, .top]: position = .topRight
			case [.left, .bottom]: position = .bottomLeft
			default: position = .bottomRight
			}
			return .frameResize(position: position, directions: .all)
		}
		return edges == .left || edges == .right ? .resizeLeftRight : .resizeUpDown
	}

	override func mouseDown(with event: NSEvent) {
		start = event.locationInWindow
		onDrag?(.began, .zero)
	}

	override func mouseDragged(with event: NSEvent) {
		guard let start else { return }
		let p = event.locationInWindow
		onDrag?(.changed, CGSize(width: p.x - start.x, height: start.y - p.y))
	}

	override func mouseUp(with event: NSEvent) {
		guard start != nil else { return }
		start = nil
		onDrag?(.ended, .zero)
	}
}

/// A minimised layer along the bottom of the layout: click to bring it back.
final class RiftFloatingCapsule: NSButton {
	let layerID: UUID
	var onPress: (() -> Void)?
	private let surface = RiftSurfaceStackView()

	init(layerID: UUID) {
		self.layerID = layerID
		super.init(frame: .zero)
		isBordered = false
		bezelStyle = .regularSquare
		wantsLayer = true
		font = .systemFont(ofSize: 12, weight: .medium)
		imagePosition = .imageLeading
		addSubview(surface, positioned: .below, relativeTo: nil)
		var style = RiftSurfaceStyle()
		style.cornerRadius = 14
		style.glass = RiftSurfaceGlass()
		style.shadows = [
			RiftSurfaceShadow(
				opacity: RiftFloatingShadow.resting.opacity,
				radius: RiftFloatingShadow.resting.radius,
				offset: CGSize(width: 0, height: RiftFloatingShadow.resting.y))
		]
		surface.style = style
		target = self
		action = #selector(pressed)
	}

	@objc private func pressed() { onPress?() }

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func layout() {
		super.layout()
		surface.frame = bounds
	}
}
