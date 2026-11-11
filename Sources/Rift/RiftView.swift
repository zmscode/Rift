import AppKit
import RiftCore

/// A view that tiles panes in a split layout.
///
/// - Drag a divider to resize; it snaps to the center with a haptic tick. Grab where two dividers
///   cross to move both. Double-click a divider to center it.
/// - Drag a pane by its header onto another pane's edge to split it, onto its middle to swap,
///   into another `RiftView` with the same `groupIdentifier` to move it there, or outside every
///   window to tear it out (see `onTearOut`).
///
/// Programmatic changes (`setLayout`, `focusedPane =`) don't call the callbacks; user actions and the
/// command methods (`split`, `close`, …) do.
open class RiftView<PaneID: Hashable & Sendable>: NSView, RiftDividerLinesHost {
	// MARK: Public state

	public private(set) var paneLayout: RiftLayout<PaneID>?
	public private(set) var zoomedPane: PaneID?
	public var focusedPane: PaneID? {
		get { focusedStorage }
		set { setFocus(newValue, notify: false, makeFirstResponder: false) }
	}

	public var configuration: RiftConfiguration { didSet { applyConfiguration() } }
	/// Panes can be dragged only between views that share this identifier.
	public var groupIdentifier = "rift.default"

	/// Creates the content view for a pane the first time it appears.
	public var makePaneView: (PaneID) -> NSView
	/// Title shown in the pane header. Defaults to the pane ID's description.
	public var paneTitle: ((PaneID) -> String)? { didSet { refreshTitles() } }

	// MARK: Callbacks

	public var onLayoutChange: ((RiftLayout<PaneID>?, RiftChangeReason) -> Void)?
	public var onFocusChange: ((PaneID?) -> Void)?
	public var onZoomChange: ((PaneID?) -> Void)?
	/// `true` when a divider drag starts, `false` when it ends. Useful for pausing expensive work.
	public var onDividerDragChanged: ((Bool) -> Void)?
	public var onPaneClosed: ((PaneID) -> Void)?
	/// A pane was dropped outside every window. It has already been removed from this view; the
	/// handler receives its content view and the drop point in screen coordinates, and would
	/// typically open a new window with `adopt(_:content:)`. Leave `nil` to disable tear-out.
	public var onTearOut: ((PaneID, NSView, CGPoint) -> Void)?
	/// Called whenever `structuralActivity` changes.
	public var onStructuralActivityChange: ((RiftStructuralActivity) -> Void)?

	/// What is reshaping the panes right now. Pane content can use it to stop scrollers flashing,
	/// pause expensive redraws, and so on, while anything is set.
	public private(set) var structuralActivity: RiftStructuralActivity = [] {
		didSet {
			guard structuralActivity != oldValue else { return }
			if structuralActivity.isEmpty != oldValue.isEmpty { updateScrollerSuppression() }
			onStructuralActivityChange?(structuralActivity)
		}
	}
	private var runningLayoutAnimations = 0
	private lazy var motion = RiftMotionDriver(view: self)
	/// The focus border is drawn once, above all panes, so it can glide between them; the
	/// departing copy fades out during a crossfade.
	private let focusOverlay = RiftFocusBorderView()
	private let departingFocusOverlay = RiftFocusBorderView()
	private let dividerLines = RiftDividerLinesView()
	private var borderPane: PaneID?
	private var borderGlides = false
	private var keyObservers: [NSObjectProtocol] = []
	private var pinch = RiftPinchRecognizer()
	private var presentations: [PaneID: RiftPanePresentation] = [:]
	private static var borderTrack: AnyHashable { "rift.focusBorder" }
	private static var layoutTrack: AnyHashable { "rift.layout" }

	// MARK: Private state

	private var focusedStorage: PaneID?
	private var containers: [PaneID: RiftPaneContainerView] = [:]
	private var pendingContent: [PaneID: NSView] = [:]
	private var placedDividers = Set<UUID>()
	private var dividerDrag: RiftDividerDrag?
	private var dividerCursor: NSCursor?
	private var dividerElements: [UUID: RiftDividerAccessibilityElement] = [:]
	private let dropIndicator = RiftDropIndicatorView()
	private var mouseMonitor: Any?
	private var trackingArea: NSTrackingArea?
	private var headlessWindow: RiftHeadlessWindow?
	private var glass: RiftGlassController?
	/// Pane sizes at the target of a running container animation (see RiftContainerAnimation).
	private var containerAnimationPaneSizes: [PaneID: CGSize]?
	/// Container animations started with `beginContainerAnimation` and not yet ended.
	var containerAnimationDepth = 0
	private var containerAnimationObservers: [NSObjectProtocol] = []
	/// Held while the pointer is over a pane header, so the system doesn't drag the window there.
	private var hoverLock: RiftMovementLockToken?
	/// Set while the system moves the window from a header; cleared on the next mouse move.
	private var isHoverLockSuspended = false
	var draggingPane: PaneID?

	// MARK: Init

	public init(
		layout: RiftLayout<PaneID>? = nil,
		configuration: RiftConfiguration = RiftConfiguration(),
		makePaneView: @escaping (PaneID) -> NSView
	) {
		self.configuration = configuration
		self.makePaneView = makePaneView
		super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
		wantsLayer = true
		dropIndicator.isHidden = true
		addSubview(dropIndicator)
		dividerLines.autoresizingMask = [.width, .height]
		addSubview(dividerLines, positioned: .below, relativeTo: dropIndicator)
		for overlay in [departingFocusOverlay, focusOverlay] {
			overlay.isFocused = true
			overlay.isHidden = true
			addSubview(overlay, positioned: .below, relativeTo: dropIndicator)
		}
		applyConfiguration()
		applyLayout(layout, animated: false)
		focusedStorage = layout?.firstPaneID
		updateFocusAppearance()
	}

	@available(*, unavailable)
	public required init?(coder: NSCoder) { fatalError("RiftView does not support NSCoder") }

	open override var isFlipped: Bool { true }

	// MARK: Layout

	/// Replaces the layout without calling `onLayoutChange`.
	public func setLayout(_ layout: RiftLayout<PaneID>?, animated: Bool = false) {
		guard layout != paneLayout else { return }
		applyLayout(layout, animated: animated)
	}

	/// The content view of a pane, if it is in the layout.
	public func contentView(for pane: PaneID) -> NSView? { containers[pane]?.contentView }

	/// A pane's frame in this view's coordinates.
	public func frame(of pane: PaneID) -> CGRect? { displayGeometry().paneFrames[pane] }

	func commit(_ layout: RiftLayout<PaneID>?, reason: RiftChangeReason, animated: Bool) {
		var next = layout
		if configuration.autoBalance, let current = next, reason != .dividerDrag, reason != .resize
		{
			placedDividers.formIntersection(current.splitIDs)
			next = current.balanced(keeping: placedDividers)
		}
		applyLayout(next, animated: animated)
		onLayoutChange?(next, reason)
	}

	private func applyLayout(_ layout: RiftLayout<PaneID>?, animated: Bool) {
		paneLayout = layout
		if let zoomed = zoomedPane, layout?.contains(zoomed) != true {
			zoomedPane = nil
			onZoomChange?(nil)
		}
		if let focused = focusedStorage, layout?.contains(focused) != true {
			focusedStorage = layout?.firstPaneID
		}
		if let layout {
			placedDividers.formIntersection(layout.splitIDs)
		} else {
			placedDividers.removeAll()
		}
		let added = reconcileContainers()
		placeContainers(animated: animated, added: added)
		updateFocusAppearance()
		rebuildAccessibility()
		window?.invalidateCursorRects(for: self)
		needsDisplay = true
	}

	/// Creates containers for new panes and drops those for panes that left. Returns the new ones.
	private func reconcileContainers() -> Set<PaneID> {
		let ids = Set(paneLayout?.paneIDs ?? [])
		for (id, container) in containers where !ids.contains(id) {
			container.removeFromSuperview()
			containers[id] = nil
		}
		var added = Set<PaneID>()
		for id in paneLayout?.paneIDs ?? [] where containers[id] == nil {
			let content = pendingContent.removeValue(forKey: id) ?? makePaneView(id)
			let container = RiftPaneContainerView(content: content)
			configure(container, for: id)
			addSubview(container, positioned: .below, relativeTo: departingFocusOverlay)
			containers[id] = container
			added.insert(id)
		}
		return added
	}

	private func configure(_ container: RiftPaneContainerView, for id: PaneID) {
		container.header.title = title(for: id)
		container.header.onMouseDown = { [weak self, weak header = container.header] event in
			self?.headerMouseDown(id, event, header: header)
		}
		container.header.onGripMouseDown = { [weak self] event in
			self?.trackPaneDrag(id, startingWith: event)
		}
		container.header.onClose = { [weak self] in self?.close(id) }
		container.strip.onHandleMouseDown = { [weak self, weak strip = container.strip] event in
			self?.trackPaneDrag(id, startingWith: event, replayingClicksThrough: strip)
		}
		container.strip.onStripMouseDown = { [weak self] event in
			self?.beginWindowDrag(from: id, with: event)
		}
		// Enter/exit events arrive even when the app is inactive (mouse-moved events don't), so
		// the lock is in place before a first click on an inactive window.
		let regionChanged: () -> Void = { [weak self] in
			self?.isHoverLockSuspended = false
			self?.refreshMovementLock()
		}
		container.strip.onPointerRegionChange = regionChanged
		container.header.onPointerRegionChange = regionChanged
		applyConfiguration(to: container)
	}

	private func applyConfiguration(to container: RiftPaneContainerView) {
		container.showsHeader = configuration.showsPaneHeaders
		container.headerHeight = configuration.headerHeight
		container.headerlessTopInset = configuration.headerlessTopInset
		container.header.showsCloseButton = configuration.showsCloseButtons
		container.cornerRadius = configuration.paneCornerRadius
		container.border.isEnabled = false  // drawn by focusOverlay
		let key = window?.isKeyWindow ?? true
		container.activeAlpha =
			key
			? 1
			: (configuration.glass.isEnabled
				? configuration.inactiveWindowPaneAlpha : configuration.inactiveWindowFocusedPaneAlpha)
		container.inactiveAlpha = key ? configuration.inactivePaneAlpha : configuration.inactiveWindowPaneAlpha
	}

	private func applyFocusBorderStyle() {
		let base = (configuration.focusBorderColor ?? .controlAccentColor)
			.withAlphaComponent(configuration.focusBorderOpacity)
		let active = window?.isKeyWindow ?? true
		let color = active
			? base
			: base.withAlphaComponent(base.alphaComponent * configuration.inactiveWindowFocusBorderOpacity)
		for overlay in [focusOverlay, departingFocusOverlay] {
			overlay.isEnabled = configuration.showsFocusBorder
			overlay.color = color
			overlay.lineWidth = configuration.focusBorderWidth
			overlay.cornerRadius = configuration.paneCornerRadius
		}
	}

	private func applyConfiguration() {
		containers.values.forEach(applyConfiguration(to:))
		dropIndicator.color = configuration.dropIndicatorColor
		dropIndicator.cornerRadius = configuration.dropIndicatorCornerRadius
		applyFocusBorderStyle()
		applyWindowFade()
		updateTrackingArea()
		updateWindowChrome()
		updateGlass()
		placeContainers(animated: false, added: [])
		needsDisplay = true
	}

	/// Creates, updates or removes the glass container behind the panes.
	private func updateGlass() {
		guard configuration.glass.isEnabled else {
			glass?.containerView.removeFromSuperview()
			glass = nil
			return
		}
		let controller = glass ?? RiftGlassController()
		if glass == nil {
			glass = controller
			controller.containerView.frame = bounds
			controller.containerView.autoresizingMask = [.width, .height]
			// Behind every pane.
			addSubview(controller.containerView, positioned: .below, relativeTo: nil)
		}
		controller.apply(configuration.glass, gap: configuration.metrics.dividerThickness)
	}

	private func placeGlass(_ frames: [PaneID: CGRect], animated: Bool) {
		guard let glass else { return }
		var keyed: [AnyHashable: CGRect] = [:]
		for (id, frame) in frames { keyed[AnyHashable(id)] = frame }
		glass.place(keyed, animated: animated)
	}

	private func title(for id: PaneID) -> String { paneTitle?(id) ?? String(describing: id) }

	private func refreshTitles() {
		for (id, container) in containers { container.header.title = title(for: id) }
		rebuildAccessibility()
	}

	/// Geometry for what is on screen: the whole layout, or only the zoomed pane.
	func displayGeometry() -> RiftGeometry<PaneID> {
		guard let layout = paneLayout else { return RiftGeometry(bounds: bounds) }
		if let zoomed = zoomedPane {
			return RiftGeometry(bounds: bounds, paneFrames: [zoomed: bounds])
		}
		var metrics = configuration.metrics
		metrics.displayScale = window?.backingScaleFactor ?? metrics.displayScale
		return layout.geometry(in: bounds, metrics: metrics)
	}

	private var effectiveMetrics: RiftMetrics {
		var metrics = configuration.metrics
		metrics.displayScale = window?.backingScaleFactor ?? metrics.displayScale
		return metrics
	}

	private var shouldAnimate: Bool {
		configuration.animationStyle.paneCurve != nil
			&& !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
			&& window != nil
	}

	private func placeContainers(
		animated: Bool, added: Set<PaneID>, curve curveOverride: RiftMotionCurve? = nil
	) {
		let geometry = displayGeometry()
		let animate = animated && shouldAnimate
		var moves: [(id: PaneID, container: RiftPaneContainerView, from: CGRect, to: CGRect)] = []
		var popping: [RiftPaneContainerView] = []
		// A new layout replaces any running layout motion, which continues from where it is now.
		motion.cancel(Self.layoutTrack, finishing: false)
		for (id, container) in containers {
			guard let frame = geometry.paneFrames[id] else {
				container.isHidden = true
				continue
			}
			container.isHidden = false
			if animate, added.contains(id) {
				// New panes pop in where they land.
				container.frame = frame
				popping.append(container)
			}
			container.alphaValue = draggingPane.flatMap { containers[$0] } === container ? 0.35 : 1
			moves.append((id, container, container.frame, frame))
		}
		refreshHeaderChrome(geometry.paneFrames)
		refreshMovementLock()
		refreshDividerLines()
		guard animate, let curve = curveOverride ?? configuration.animationStyle.paneCurve else {
			for move in moves {
				move.container.frame = move.to
				if runningLayoutAnimations == 0 { publishPresentation(for: move.id, settled: true) }
			}
			placeGlass(geometry.paneFrames, animated: false)
			syncFocusBorderFrame()
			return
		}
		popping.forEach(popIn)
		for move in moves {
			publishPresentation(
				for: move.id, settled: false, target: contentSize(forPaneFrame: move.to))
		}
		let timing = RiftMotionTiming(duration: curve.transitionDuration, curve: curve)
		let changed = moves.filter { $0.from != $0.to }
		runningLayoutAnimations += 1
		structuralActivity.insert(.structuralTransition)
		motion.run(
			Self.layoutTrack, duration: timing.duration,
			apply: { [weak self] elapsed in
				guard let self else { return }
				let progress = timing.progress(elapsed: elapsed)
				var frames: [PaneID: CGRect] = [:]
				for move in moves { frames[move.id] = move.to }
				for move in changed {
					let frame = move.from.rift_interpolated(to: move.to, progress: progress)
					move.container.frame = frame
					frames[move.id] = frame
				}
				self.placeGlass(frames, animated: false)
				self.syncFocusBorderFrame()
			},
			completion: { [weak self] in
				guard let self else { return }
				// The layout has settled once the last running motion ends.
				if self.runningLayoutAnimations == 1 {
					for id in self.containers.keys { self.publishPresentation(for: id, settled: true) }
				}
				// Pane content keeps scrollers hidden for 0.15s after the motion settles.
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
					guard let self else { return }
					self.runningLayoutAnimations = max(0, self.runningLayoutAnimations - 1)
					if self.runningLayoutAnimations == 0 {
						self.structuralActivity.remove(.structuralTransition)
					}
				}
			})
	}

	/// Scales a new pane up from the pop-in scale while it fades in.
	private func popIn(_ container: RiftPaneContainerView) {
		guard let pop = configuration.panePopIn else { return }
		container.wantsLayer = true
		container.alphaValue = 0
		motion.run(
			ObjectIdentifier(container), duration: max(pop.entry.duration, pop.fadeIn.duration),
			apply: { [weak container] elapsed in
				guard let container else { return }
				let grow = pop.entry.progress(elapsed: elapsed)
				container.rift_setPresentationScale(CGFloat(pop.scale + (1 - pop.scale) * grow))
				container.alphaValue = CGFloat(min(max(pop.fadeIn.progress(elapsed: elapsed), 0), 1))
			},
			completion: { [weak container] in
				container?.rift_setPresentationScale(1)
				container?.alphaValue = 1
			})
	}

	open override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		placeContainers(animated: false, added: [])
		rebuildAccessibility()
		window?.invalidateCursorRects(for: self)
	}

	func refreshDividerLines() {
		dividerLines.frame = bounds
		let rects =
			configuration.showsDividerLines && zoomedPane == nil
			? displayGeometry().dividers.map { dividerLines.convert($0.line, from: self) } : []
		dividerLines.show(
			rects, color: configuration.dividerColor, blendMode: configuration.dividerBlendMode)
	}

	// MARK: Commands

	/// Splits `pane` (default: the focused pane), placing `newPane` on `edge`. Focuses the new pane.
	@discardableResult
	public func split(
		_ pane: PaneID? = nil, edge: RiftEdge, newPane: PaneID, position: Double = 0.5
	) -> Bool {
		let target = pane ?? focusedStorage
		let next: RiftLayout<PaneID>?
		if let layout = paneLayout {
			guard let target else { return false }
			next = layout.splitting(target, with: newPane, edge: edge, position: position)
		} else {
			next = .pane(newPane)
		}
		guard let next else { return false }
		setZoom(nil)
		commit(next, reason: .split, animated: true)
		setFocus(newPane, notify: true, makeFirstResponder: true)
		return true
	}

	/// Splits the full width or height of the layout, placing `newPane` along `edge`.
	@discardableResult
	public func splitAll(edge: RiftEdge, newPane: PaneID, position: Double = 0.5) -> Bool {
		guard let layout = paneLayout else { return split(edge: edge, newPane: newPane) }
		guard let next = layout.wrapping(.pane(newPane), edge: edge, position: position) else {
			return false
		}
		setZoom(nil)
		commit(next, reason: .split, animated: true)
		setFocus(newPane, notify: true, makeFirstResponder: true)
		return true
	}

	/// Closes `pane` (default: the focused pane). Focus moves to its neighbour.
	@discardableResult
	public func close(_ pane: PaneID? = nil) -> Bool {
		guard let id = pane ?? focusedStorage, let layout = paneLayout,
			let removal = layout.removing(.pane(id))
		else { return false }
		let wasFocused = focusedStorage == id
		if let container = containers.removeValue(forKey: id) { fadeOutAndRemove(container) }
		if wasFocused { focusedStorage = removal.preferredFocus }
		commit(removal.remaining, reason: .close, animated: true)
		if wasFocused { setFocus(removal.preferredFocus, notify: true, makeFirstResponder: true) }
		onPaneClosed?(id)
		return true
	}

	/// Shrinks a closed pane to the pop-in scale while it fades out, then removes it.
	private func fadeOutAndRemove(_ container: RiftPaneContainerView) {
		guard shouldAnimate, let pop = configuration.panePopIn else {
			container.removeFromSuperview()
			return
		}
		container.wantsLayer = true
		motion.run(
			ObjectIdentifier(container), duration: max(pop.exit.duration, pop.fadeOut.duration),
			apply: { [weak container] elapsed in
				guard let container else { return }
				let shrink = pop.exit.progress(elapsed: elapsed)
				container.rift_setPresentationScale(CGFloat(1 - (1 - pop.scale) * shrink))
				container.alphaValue = CGFloat(1 - min(max(pop.fadeOut.progress(elapsed: elapsed), 0), 1))
			},
			completion: { [weak container] in
				container?.removeFromSuperview()
				container?.rift_setPresentationScale(1)
			})
	}

	/// Focuses a pane, making its content first responder.
	public func focus(_ pane: PaneID) {
		guard paneLayout?.contains(pane) == true else { return }
		if let zoomed = zoomedPane, zoomed != pane { setZoom(nil) }
		setFocus(pane, notify: true, makeFirstResponder: true)
	}

	/// Moves focus to the neighbouring pane.
	@discardableResult
	public func moveFocus(_ direction: RiftDirection, wraps: Bool = true) -> Bool {
		guard zoomedPane == nil, let layout = paneLayout, let current = focusedStorage,
			let next = layout.neighbor(of: current, toward: direction, wraps: wraps)
		else { return false }
		focus(next)
		return true
	}

	/// Grows `pane` (default: focused) toward `direction`. `points` defaults to
	/// `keyboardResizeFraction` of the split being resized.
	@discardableResult
	public func resize(
		_ pane: PaneID? = nil, toward direction: RiftDirection, by points: CGFloat? = nil
	) -> Bool {
		guard let id = pane ?? focusedStorage, let layout = paneLayout,
			let splitID = layout.splitID(bordering: id, on: direction.edge)
		else { return false }
		let metrics = effectiveMetrics
		let amount =
			points
			?? {
				let divider = layout.geometry(in: bounds, metrics: metrics).divider(splitID)
				return CGFloat(configuration.keyboardResizeFraction) * (divider?.available ?? 0)
			}()
		guard
			let next = layout.resizing(
				id, toward: direction, by: amount, in: bounds, metrics: metrics),
			next != layout
		else { return false }
		placedDividers.insert(splitID)
		commit(next, reason: .resize, animated: true)
		return true
	}

	/// Swaps `pane` (default: focused) with its neighbour in `direction`.
	@discardableResult
	public func swap(_ pane: PaneID? = nil, toward direction: RiftDirection) -> Bool {
		guard zoomedPane == nil, let id = pane ?? focusedStorage, let layout = paneLayout,
			let other = layout.swapNeighbor(
				of: id, toward: direction, in: bounds, metrics: effectiveMetrics),
			let next = layout.swapping(id, other)
		else { return false }
		commit(next, reason: .move, animated: true)
		return true
	}

	/// Closes every pane except `pane` (default: focused), which keeps focus.
	@discardableResult
	public func closeOthers(_ pane: PaneID? = nil) -> Bool {
		guard let keep = pane ?? focusedStorage, let layout = paneLayout, layout.contains(keep),
			layout.paneCount > 1
		else { return false }
		let closed = layout.paneIDs.filter { $0 != keep }
		for id in closed {
			if let container = containers.removeValue(forKey: id) { fadeOutAndRemove(container) }
		}
		setZoom(nil)
		commit(.pane(keep), reason: .close, animated: true)
		setFocus(keep, notify: true, makeFirstResponder: true)
		closed.forEach { onPaneClosed?($0) }
		return true
	}

	/// Shares space evenly between panes.
	public func balance(keepingDraggedDividers: Bool = false) {
		guard let layout = paneLayout else { return }
		if !keepingDraggedDividers { placedDividers.removeAll() }
		commit(
			layout.balanced(keeping: keepingDraggedDividers ? placedDividers : []),
			reason: .balance, animated: true)
	}

	/// Fills the view with `pane` (default: focused), or restores the layout if it is already zoomed.
	public func toggleZoom(_ pane: PaneID? = nil) {
		if zoomedPane != nil { setZoom(nil) } else { setZoom(pane ?? focusedStorage) }
	}

	public func setZoom(_ pane: PaneID?) {
		let target = pane.flatMap { paneLayout?.contains($0) == true ? $0 : nil }
		guard target != zoomedPane else { return }
		zoomedPane = target
		if let target { setFocus(target, notify: true, makeFirstResponder: true) }
		placeContainers(animated: true, added: [], curve: configuration.animationStyle.chromeCurve)
		rebuildAccessibility()
		window?.invalidateCursorRects(for: self)
		needsDisplay = true
		onZoomChange?(target)
	}

	/// Adds a pane whose content view already exists (for example one torn out of another view).
	@discardableResult
	public func adopt(
		_ pane: PaneID,
		content: NSView,
		beside target: PaneID? = nil,
		edge: RiftEdge = .right,
		reason: RiftChangeReason = .transferIn
	) -> Bool {
		let next: RiftLayout<PaneID>
		if let layout = paneLayout {
			guard !layout.contains(pane) else { return false }
			let anchor =
				target.flatMap { layout.contains($0) ? $0 : nil } ?? focusedStorage
				?? layout.lastPaneID
			guard let split = layout.splitting(anchor, with: pane, edge: edge) else { return false }
			next = split
		} else {
			next = .pane(pane)
		}
		pendingContent[pane] = content
		setZoom(nil)
		commit(next, reason: reason, animated: true)
		setFocus(pane, notify: true, makeFirstResponder: true)
		return true
	}

	/// Removes a pane but keeps its content view alive and returns it.
	func detach(_ pane: PaneID, reason: RiftChangeReason) -> NSView? {
		guard let layout = paneLayout, let removal = layout.removing(.pane(pane)),
			let container = containers.removeValue(forKey: pane)
		else { return nil }
		let content = container.detachContent()
		container.removeFromSuperview()
		let wasFocused = focusedStorage == pane
		if wasFocused { focusedStorage = removal.preferredFocus }
		commit(removal.remaining, reason: reason, animated: true)
		if wasFocused { onFocusChange?(focusedStorage) }
		return content
	}

	// MARK: Focus

	func setFocus(_ pane: PaneID?, notify: Bool, makeFirstResponder: Bool) {
		let target = pane.flatMap { paneLayout?.contains($0) == true ? $0 : nil }
		let changed = target != focusedStorage
		focusedStorage = target
		updateFocusAppearance()
		if makeFirstResponder, let target, let content = containers[target]?.contentView {
			if let responder = firstResponderCandidate(in: content) {
				window?.makeFirstResponder(responder)
			}
		}
		if changed, notify { onFocusChange?(target) }
	}

	private func firstResponderCandidate(in view: NSView) -> NSView? {
		var queue = [view]
		while !queue.isEmpty {
			let next = queue.removeFirst()
			if next.acceptsFirstResponder { return next }
			queue.append(contentsOf: next.subviews)
		}
		return nil
	}

	private func updateFocusAppearance() {
		for (id, container) in containers { container.isFocused = id == focusedStorage }
		updateFocusBorder(animated: true)
	}

	/// Moves the focus border to the focused pane, gliding or crossfading when it changes pane.
	private func updateFocusBorder(animated: Bool) {
		guard configuration.showsFocusBorder, let pane = focusedStorage,
			let target = containers[pane], !target.isHidden
		else {
			motion.cancel(Self.borderTrack, finishing: false)
			focusOverlay.isHidden = true
			departingFocusOverlay.isHidden = true
			borderPane = nil
			return
		}
		let previous = borderPane
		borderPane = pane
		let moved = previous != nil && previous != pane && !focusOverlay.isHidden
		focusOverlay.isHidden = false
		let transition = shouldAnimate && animated && moved ? configuration.focusBorderTransition : .off
		switch transition {
		case .off:
			if previous == pane, motion.isRunning(Self.borderTrack) { return }
			motion.cancel(Self.borderTrack, finishing: false)
			borderGlides = false
			departingFocusOverlay.isHidden = true
			focusOverlay.alphaValue = 1
			focusOverlay.frame = target.frame
		case .glide:
			guard let curve = configuration.animationStyle.paneCurve else { return }
			let timing = RiftMotionTiming(duration: curve.borderGlideDuration, curve: curve)
			let start = focusOverlay.frame
			departingFocusOverlay.isHidden = true
			focusOverlay.alphaValue = 1
			borderGlides = true
			motion.run(
				Self.borderTrack, duration: timing.duration,
				apply: { [weak self, weak target] elapsed in
					guard let self, let target else { return }
					self.focusOverlay.frame = start.rift_interpolated(
						to: target.frame, progress: timing.progress(elapsed: elapsed))
				},
				completion: { [weak self] in self?.borderGlides = false })
		case .crossfade:
			let timing = RiftMotionTiming.borderCrossfade(timeScale: configuration.popInTimeScale)
			departingFocusOverlay.frame = focusOverlay.frame
			departingFocusOverlay.isHidden = false
			focusOverlay.frame = target.frame
			borderGlides = false
			motion.run(
				Self.borderTrack, duration: timing.duration,
				apply: { [weak self] elapsed in
					guard let self else { return }
					let p = CGFloat(min(max(timing.progress(elapsed: elapsed), 0), 1))
					self.focusOverlay.alphaValue = p
					self.departingFocusOverlay.alphaValue = 1 - p
				},
				completion: { [weak self] in
					self?.departingFocusOverlay.isHidden = true
					self?.focusOverlay.alphaValue = 1
				})
		}
	}

	private func contentSize(forPaneFrame frame: CGRect) -> CGSize {
		let top =
			configuration.showsPaneHeaders ? configuration.headerHeight : configuration.headerlessTopInset
		return CGSize(width: frame.width, height: max(0, frame.height - top))
	}

	/// Tells content that adopts `RiftPanePresentationObserving` about a change, if there is one.
	private func publishPresentation(for id: PaneID, settled: Bool, target: CGSize? = nil) {
		guard let container = containers[id],
			let observer = container.contentView as? RiftPanePresentationObserving
		else { return }
		let presentation = RiftPanePresentation(
			isLayoutSettled: settled, zoomFraction: zoomedPane == id ? 1 : 0,
			contentSize: container.contentView.bounds.size, targetSize: settled ? nil : target)
		guard presentations[id] != presentation else { return }
		presentations[id] = presentation
		observer.riftPanePresentationDidChange(presentation)
	}

	/// Pane content alpha for the window's key state.
	private func applyWindowFade() {
		let key = window?.isKeyWindow ?? true
		// With glass, content fades equally in every pane of a background window.
		let focusedInactive =
			configuration.glass.isEnabled
			? configuration.inactiveWindowPaneAlpha : configuration.inactiveWindowFocusedPaneAlpha
		for container in containers.values {
			container.activeAlpha = key ? 1 : focusedInactive
			container.inactiveAlpha =
				key ? configuration.inactivePaneAlpha : configuration.inactiveWindowPaneAlpha
		}
	}

	/// Hides (or restores) the scrollers of scroll views inside the panes.
	private var suppressedScrollers: [ObjectIdentifier: (NSScroller, CGFloat)] = [:]
	private func updateScrollerSuppression() {
		if structuralActivity.isEmpty || !configuration.hidesScrollersDuringStructuralChanges {
			for (scroller, alpha) in suppressedScrollers.values { scroller.alphaValue = alpha }
			suppressedScrollers.removeAll()
			return
		}
		func visit(_ view: NSView) {
			if let scrollView = view as? NSScrollView {
				for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller]
				.compactMap({ $0 }) where suppressedScrollers[ObjectIdentifier(scroller)] == nil {
					suppressedScrollers[ObjectIdentifier(scroller)] = (scroller, scroller.alphaValue)
					scroller.alphaValue = 0
				}
			}
			view.subviews.forEach(visit)
		}
		containers.values.forEach { visit($0) }
	}

	/// Keeps the focus border on the focused pane while panes move (a glide tracks it itself).
	private func syncFocusBorderFrame() {
		guard !borderGlides, let pane = borderPane, let target = containers[pane] else { return }
		focusOverlay.frame = target.frame
		if target.isHidden { updateFocusBorder(animated: false) }
	}

	open override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if let monitor = mouseMonitor {
			NSEvent.removeMonitor(monitor)
			mouseMonitor = nil
		}
		guard window != nil else {
			containerAnimationDepth = 0
			RiftViewRegistry.unregister(self)
			return
		}
		updateWindowChrome()
		RiftViewRegistry.register(self)
		keyObservers.forEach(NotificationCenter.default.removeObserver)
		keyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
			NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) {
				[weak self] _ in
				MainActor.assumeIsolated {
					self?.applyFocusBorderStyle()
					self?.applyWindowFade()
				}
			}
		}
		applyFocusBorderStyle()
		observeContainerAnimations()
		// Clicking anywhere in a pane focuses it, without stealing the click from the content.
		mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [
			.leftMouseDown, .rightMouseDown, .otherMouseDown,
		]) {
			[weak self] event in
			MainActor.assumeIsolated { self?.focusPane(under: event) }
			return event
		}
		placeContainers(animated: false, added: [])
		updateTrackingArea()
	}

	// MARK: Container animations

	private func observeContainerAnimations() {
		guard containerAnimationObservers.isEmpty else { return }
		let center = NotificationCenter.default
		containerAnimationObservers.append(
			center.addObserver(
				forName: RiftContainerAnimation.willBeginNotification, object: nil, queue: .main
			) { [weak self] note in
				let object = (note.object as AnyObject?).map(ObjectIdentifier.init)
				let widthChange =
					(note.userInfo?[RiftContainerAnimation.widthChangeKey] as? NSNumber)?.doubleValue
				let contentWidth =
					(note.userInfo?[RiftContainerAnimation.contentWidthKey] as? NSNumber)?.doubleValue
				MainActor.assumeIsolated {
					self?.containerAnimationWillBegin(
						object: object, widthChange: widthChange, contentWidth: contentWidth)
				}
			})
		containerAnimationObservers.append(
			center.addObserver(
				forName: RiftContainerAnimation.didEndNotification, object: nil, queue: .main
			) { [weak self] note in
				let object = (note.object as AnyObject?).map(ObjectIdentifier.init)
				MainActor.assumeIsolated { self?.containerAnimationDidEnd(object: object) }
			})
	}

	private func isOwnWindow(_ object: ObjectIdentifier?) -> Bool {
		guard let window, let object else { return false }
		return object == ObjectIdentifier(window)
	}

	/// Lays the panes out once at the size this view will have when the animation ends, and holds
	/// each pane's content at that size until it does.
	private func containerAnimationWillBegin(
		object: ObjectIdentifier?, widthChange: Double?, contentWidth: Double?
	) {
		guard isOwnWindow(object), let widthChange, let layout = paneLayout,
			let target = RiftContainerAnimationMath.targetLayoutSize(
				layoutSize: bounds.size, contentWidth: contentWidth.map { CGFloat($0) },
				widthChange: CGFloat(widthChange))
		else { return }
		let targetBounds = CGRect(origin: .zero, size: target)
		var sizes: [PaneID: CGSize] = [:]
		if let zoomed = zoomedPane {
			sizes[zoomed] = target
		} else {
			for (id, frame) in layout.geometry(in: targetBounds, metrics: effectiveMetrics).paneFrames {
				sizes[id] = frame.size
			}
		}
		// Hold each pane's content at the larger of the size it has now and the size it will end
		// at, so it reflows at most once and never leaves part of its pane uncovered: a shrinking
		// pane clips its content, a growing pane reveals it. A begin that interrupts another only
		// ever grows the held size.
		for (id, container) in containers {
			guard let target = sizes[id] else { continue }
			let current = container.pinnedPaneSize ?? container.bounds.size
			sizes[id] = CGSize(
				width: max(target.width, current.width), height: max(target.height, current.height))
		}
		containerAnimationPaneSizes = sizes
		for (id, container) in containers { container.pinnedPaneSize = sizes[id] }
	}

	private func containerAnimationDidEnd(object: ObjectIdentifier?) {
		guard isOwnWindow(object), containerAnimationPaneSizes != nil else { return }
		containerAnimationPaneSizes = nil
		for container in containers.values { container.pinnedPaneSize = nil }
		placeContainers(animated: false, added: [])
	}

	open override func viewWillMove(toWindow newWindow: NSWindow?) {
		super.viewWillMove(toWindow: newWindow)
		if newWindow !== window, let lock = hoverLock {
			hoverLock = nil
			lock.release()
		}
		if newWindow !== window, let headless = headlessWindow {
			headlessWindow = nil
			headless.restore()
		}
	}

	// MARK: Window chrome

	/// Whether the window is currently headless (not in full screen, where the buttons move away).
	public var isHeadlessActive: Bool {
		headlessWindow != nil && window?.styleMask.contains(.fullScreen) == false
	}

	private var headerMovesWindow: Bool {
		switch configuration.headerDragBehavior {
		case .automatic: isHeadlessActive
		case .movePane: false
		case .moveWindow: true
		}
	}

	private func updateWindowChrome() {
		if configuration.windowStyle == .headless, let window {
			if headlessWindow?.window !== window {
				headlessWindow?.restore()
				let headless = RiftHeadlessWindow(
					window: window, rowHeight: configuration.headerHeight)
				headless.onLayout = { [weak self] in self?.refreshHeaderChrome() }
				headlessWindow = headless
			} else {
				headlessWindow?.rowHeight = configuration.headerHeight
			}
		} else if let headless = headlessWindow {
			headlessWindow = nil
			headless.restore()
		}
		refreshHeaderChrome()
	}

	private func refreshHeaderChrome() { refreshHeaderChrome(displayGeometry().paneFrames) }

	/// Shows headers on the top row in headless mode and keeps them clear of the window buttons.
	private func refreshHeaderChrome(_ frames: [PaneID: CGRect]) {
		let headless = isHeadlessActive
		var atWindowTop = false
		var buttons: CGRect?
		if headless, let window, let contentHeight = window.contentView?.bounds.height {
			atWindowTop = convert(bounds, to: nil).maxY >= contentHeight - 1
			buttons = headlessWindow?.buttonGroupFrame.map { convert($0, from: nil) }
		}
		let showsGrip =
			headerMovesWindow && configuration.allowsPaneDragging && configuration.showsPaneHeaders
		for (id, container) in containers {
			guard let frame = frames[id] else { continue }
			let touchesTop = atWindowTop && frame.minY <= bounds.minY + 0.5
			container.showsHeader = configuration.showsPaneHeaders
			container.header.isBare = false
			container.header.showsGrip = showsGrip
			// Distance from the pane's left edge to just past the window buttons, if they sit over it.
			var clearance: CGFloat = 0
			if touchesTop, let buttons, buttons.maxX > frame.minX, buttons.minX < frame.maxX {
				let reserved = configuration.windowButtonInset.map { convert(CGPoint(x: $0, y: 0), from: nil).x }
					?? buttons.maxX + configuration.windowButtonSpacing
				clearance = max(0, reserved - frame.minX)
			}
			container.header.leadingInset = max(0, clearance - 6)
			// Invisible strip: the corner after the buttons drags the pane; on the top row of a
			// headless window, the rest of it drags the window.
			container.strip.leadingInset = clearance
			container.strip.handleWidth = configuration.dragHandleWidth
			container.strip.allowsPaneDrag = configuration.allowsPaneDragging
			container.strip.movesWindow =
				touchesTop && configuration.headerDragBehavior != .movePane
		}
	}

	/// Locks the window while the pointer is over a visible pane header, and unlocks it otherwise.
	/// Recomputed from the real pointer position, so a lock can't leak when exit events are missed
	/// (they aren't delivered during a drag's tracking loop).
	func refreshMovementLock() {
		var overHeader = false
		if let window, window.isVisible, !isHoverLockSuspended, !isHiddenOrHasHiddenAncestor {
			let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
			overHeader = containers.values.contains { container in
				guard !container.isHidden else { return false }
				if container.showsHeader {
					return container.convert(container.header.frame, to: self).contains(point)
				}
				return container.strip.handlesPoint(container.strip.convert(point, from: self))
			}
		}
		if overHeader, hoverLock == nil, let window {
			hoverLock = RiftWindowMovementLock.acquire(window)
		} else if !overHeader, let lock = hoverLock {
			hoverLock = nil
			lock.release()
		}
	}

	private func headerMouseDown(_ pane: PaneID, _ event: NSEvent, header: RiftPaneHeaderView?) {
		guard headerMovesWindow, !event.modifierFlags.contains(.option) else {
			trackPaneDrag(pane, startingWith: event)
			return
		}
		beginWindowDrag(from: pane, with: event)
	}

	/// Moves the window from a header or the top strip: focuses the pane, handles a double-click
	/// like a titlebar, and otherwise hands the drag to the system once the mouse really moves.
	private func beginWindowDrag(from pane: PaneID, with event: NSEvent) {
		guard let window else { return }
		if focusedStorage != pane { setFocus(pane, notify: true, makeFirstResponder: true) }
		if event.clickCount == 2 {
			RiftHeadlessWindow.performTitlebarDoubleClick(on: window, event: event)
			return
		}
		// Hand the drag to the system straight away on mouse-down. The header holds the window
		// still while hovered (see RiftWindowMovementLock), so lift that first.
		isHoverLockSuspended = true
		refreshMovementLock()
		guard !RiftWindowMovementLock.isLocked(window) else {
			isHoverLockSuspended = false
			refreshMovementLock()
			return
		}
		window.performDrag(with: event)
	}

	private func focusPane(under event: NSEvent) {
		guard event.window === window, !isHiddenOrHasHiddenAncestor else { return }
		let point = convert(event.locationInWindow, from: nil)
		guard bounds.contains(point), dividerHit(at: point) == nil,
			let id = displayGeometry().pane(at: point), id != focusedStorage
		else { return }
		setFocus(id, notify: true, makeFirstResponder: false)
	}

	private func updateTrackingArea() {
		if let trackingArea { removeTrackingArea(trackingArea) }
		trackingArea = nil
		// Used for focus-follows-mouse and for the window movement lock over pane headers.
		let area = NSTrackingArea(
			rect: .zero,
			options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
			owner: self, userInfo: nil)
		addTrackingArea(area)
		trackingArea = area
	}

	open override func mouseEntered(with event: NSEvent) {
		super.mouseEntered(with: event)
		refreshMovementLock()
	}

	open override func mouseExited(with event: NSEvent) {
		super.mouseExited(with: event)
		isHoverLockSuspended = false
		refreshMovementLock()
	}

	open override func mouseMoved(with event: NSEvent) {
		super.mouseMoved(with: event)
		isHoverLockSuspended = false
		refreshMovementLock()
		guard configuration.focusFollowsMouse, window?.isKeyWindow == true,
			dividerDrag == nil, draggingPane == nil
		else { return }
		let point = convert(event.locationInWindow, from: nil)
		if let id = displayGeometry().pane(at: point), id != focusedStorage {
			setFocus(id, notify: true, makeFirstResponder: true)
		}
	}

	// MARK: Divider dragging

	func dividerHit(at point: CGPoint) -> RiftDividerHit? {
		guard configuration.allowsDividerDragging, zoomedPane == nil, draggingPane == nil else {
			return nil
		}
		return displayGeometry().dividerHit(
			at: point, hitThickness: configuration.metrics.dividerHitThickness)
	}

	open override func hitTest(_ point: NSPoint) -> NSView? {
		guard !isHidden else { return nil }
		let local = convert(point, from: superview)
		if bounds.contains(local), dividerHit(at: local) != nil { return self }
		return super.hitTest(point)
	}

	open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	/// Spread two fingers over a pane to zoom it; pinch to restore the layout.
	open override func magnify(with event: NSEvent) {
		guard configuration.allowsPinchToZoom else {
			super.magnify(with: event)
			return
		}
		if event.phase.contains(.began) { pinch.begin() }
		switch pinch.update(magnification: Double(event.magnification)) {
		case .spread?:
			let point = convert(event.locationInWindow, from: nil)
			if zoomedPane == nil, let pane = displayGeometry().pane(at: point) { setZoom(pane) }
		case .pinch?:
			if zoomedPane != nil { setZoom(nil) }
		case nil:
			break
		}
	}
	open override var mouseDownCanMoveWindow: Bool { false }

	private func cursor(for hit: RiftDividerHit, at point: CGPoint? = nil) -> NSCursor {
		if #available(macOS 15.0, *) {
			switch hit.axis {
			case .horizontal: return .columnResize(directions: .all)
			case .vertical: return .rowResize(directions: .all)
			case nil:
				// Where two dividers cross, the cursor points into the quadrant the pointer is in.
				guard let point, let crossing = hit.crossingPoint else { return .crosshair }
				let position: NSCursor.FrameResizePosition =
					point.y < crossing.y
					? (point.x < crossing.x ? .topLeft : .topRight)
					: (point.x < crossing.x ? .bottomLeft : .bottomRight)
				return .frameResize(position: position, directions: .all)
			}
		}
		switch hit.axis {
		case .horizontal: return .resizeLeftRight
		case .vertical: return .resizeUpDown
		case nil: return .crosshair
		}
	}

	open override func resetCursorRects() {
		super.resetCursorRects()
		guard configuration.allowsDividerDragging, zoomedPane == nil else { return }
		for divider in displayGeometry().dividers {
			let rect = divider.hitRect(thickness: configuration.metrics.dividerHitThickness)
			addCursorRect(rect, cursor: cursor(for: RiftDividerHit(dividers: [divider])))
		}
	}

	open override func mouseDown(with event: NSEvent) {
		let point = convert(event.locationInWindow, from: nil)
		guard let hit = dividerHit(at: point), let layout = paneLayout else {
			super.mouseDown(with: event)
			return
		}
		if event.clickCount == 2, configuration.doubleClickCentersDivider {
			// Double-click centers the divider(s).
			let updates = hit.dividers.map { RiftDividerUpdate(splitID: $0.splitID, position: 0.5) }
			placedDividers.subtract(updates.map(\.splitID))
			commit(layout.applying(updates), reason: .dividerDrag, animated: true)
			return
		}
		dividerDrag = RiftDividerDrag(hit: hit, pointer: point)
		let cursor = cursor(for: hit, at: point)
		dividerCursor = cursor
		window?.disableCursorRects()
		cursor.set()
		structuralActivity.insert(.dividerDrag)
		onDividerDragChanged?(true)
	}

	open override func mouseDragged(with event: NSEvent) {
		guard var drag = dividerDrag, let layout = paneLayout else {
			super.mouseDragged(with: event)
			return
		}
		let point = convert(event.locationInWindow, from: nil)
		let result = drag.update(
			pointer: point, geometry: displayGeometry(), metrics: effectiveMetrics,
			snap: configuration.snap)
		dividerDrag = drag
		dividerCursor?.set()
		let next = layout.applying(result.updates)
		placedDividers.formUnion(result.updates.map(\.splitID))
		guard next != layout else { return }
		if result.didSnap, configuration.hapticFeedback {
			NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
		}
		commit(next, reason: .dividerDrag, animated: false)
	}

	open override func mouseUp(with event: NSEvent) {
		guard dividerDrag != nil else {
			super.mouseUp(with: event)
			return
		}
		dividerDrag = nil
		dividerCursor = nil
		window?.enableCursorRects()
		window?.invalidateCursorRects(for: self)
		structuralActivity.remove(.dividerDrag)
		onDividerDragChanged?(false)
	}

	// MARK: Pane drag and drop

	/// Runs a pane drag that started with `event` (a left mouse-down). The built-in header calls
	/// this; call it from your own drag handle's `mouseDown(with:)` to make it draggable too.
	/// Returns once the mouse is released. A press without movement just focuses the pane.
	public func trackPaneDrag(_ pane: PaneID, startingWith event: NSEvent) {
		trackPaneDrag(pane, startingWith: event, replayingClicksThrough: nil)
	}

	/// - Parameter replayView: a handle sitting over the pane's content. A press that ends without
	///   any drag is sent again to the window with this view ignoring the mouse, so the content
	///   underneath gets the click.
	func trackPaneDrag(
		_ pane: PaneID, startingWith event: NSEvent, replayingClicksThrough replayView: RiftPaneDragStripView?
	) {
		guard let window, paneLayout?.contains(pane) == true else { return }
		guard configuration.allowsPaneDragging else {
			focus(pane)
			return
		}
		// Hold the window still for the whole drag, even once the pointer leaves the header.
		let lock = RiftWindowMovementLock.acquire(window)
		defer {
			lock.release()
			refreshMovementLock()
		}
		let start = event.locationInWindow
		let mouseDown = event
		let state = RiftDragTrackingState<PaneID>()
		window.trackEvents(
			matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
			timeout: NSEvent.foreverDuration,
			mode: .eventTracking
		) { [weak self] event, stop in
			let finished = MainActor.assumeIsolated { () -> Bool in
				guard let self, let event else { return true }
				return self.handlePaneDragEvent(
					event, pane: pane, start: start, state: state, mouseDown: mouseDown,
					replayView: replayView)
			}
			if finished { stop.pointee = true }
		}
	}

	/// Returns `true` when tracking should stop.
	private func handlePaneDragEvent(
		_ event: NSEvent, pane: PaneID, start: CGPoint, state: RiftDragTrackingState<PaneID>,
		mouseDown: NSEvent, replayView: RiftPaneDragStripView?
	) -> Bool {
		// Use the event's own location rather than the global cursor position, so the drop matches
		// exactly where the release happened.
		let screenPoint =
			event.window.map { $0.convertPoint(toScreen: event.locationInWindow) }
			?? NSEvent.mouseLocation
		switch event.type {
		case .leftMouseDragged:
			if state.session == nil {
				let distance = hypot(
					event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
				guard distance >= configuration.dragStartDistance else { return false }
				let grab = convert(start, from: nil)
				guard let session = RiftPaneDragSession(source: self, pane: pane, grabPoint: grab)
				else { return true }
				state.session = session
			}
			state.session?.move(to: screenPoint)
			return false
		case .leftMouseUp:
			if let session = state.session {
				session.drop(at: screenPoint)
			} else {
				focus(pane)
				if let replayView, let window {
					replayView.isReplayingClick = true
					window.sendEvent(mouseDown)
					window.sendEvent(event)
					replayView.isReplayingClick = false
				}
			}
			return true
		case .keyDown where event.keyCode == 53:  // Escape
			state.session?.cancel()
			return true
		default:
			return false
		}
	}

	/// Where a pane dragged from `source` would land at `point` (this view's coordinates).
	func dropTarget(at point: CGPoint, pane: PaneID, from source: RiftView<PaneID>)
		-> RiftDropTarget<PaneID>?
	{
		guard bounds.contains(point) else { return nil }
		guard paneLayout != nil else {
			return RiftDropTarget(
				pane: nil, zone: .center,
				indicator: bounds.insetBy(
					dx: configuration.dropIndicatorInset, dy: configuration.dropIndicatorInset))
		}
		let geometry = displayGeometry()
		guard let target = geometry.pane(at: point), let frame = geometry.paneFrames[target] else {
			return nil
		}
		if source === self, target == pane { return nil }
		let zone = RiftDropZone.classify(point, in: frame, preferredBand: configuration.dropBand)
		// The middle of a pane swaps, which only works inside one view. Anywhere else (or with
		// centre drops turned off) the middle is not a drop target.
		if zone == .center, source !== self || !configuration.allowsCenterDrop { return nil }
		return RiftDropTarget(
			pane: target, zone: zone,
			indicator: zone.indicatorRect(in: frame, inset: configuration.dropIndicatorInset))
	}

	func showDropIndicator(_ rect: CGRect?) {
		guard let rect else {
			dropIndicator.isHidden = true
			return
		}
		// The highlight jumps straight to each new zone.
		dropIndicator.frame = rect
		dropIndicator.isHidden = false
		dropIndicator.needsDisplay = true
	}

	func setDragging(_ pane: PaneID?) {
		if let previous = draggingPane { containers[previous]?.alphaValue = 1 }
		draggingPane = pane
		if let pane { containers[pane]?.alphaValue = 0.35 }
		if pane != nil {
			structuralActivity.insert(.paneDrag)
		} else {
			structuralActivity.remove(.paneDrag)
		}
	}

	open override func viewWillStartLiveResize() {
		super.viewWillStartLiveResize()
		structuralActivity.insert(.windowLiveResize)
	}

	open override func viewDidEndLiveResize() {
		super.viewDidEndLiveResize()
		structuralActivity.remove(.windowLiveResize)
	}

	/// A snapshot of a pane, used for the drag preview.
	func snapshot(of pane: PaneID) -> NSImage? {
		guard let container = containers[pane], container.bounds.width > 0,
			container.bounds.height > 0,
			let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)
		else { return nil }
		container.cacheDisplay(in: container.bounds, to: rep)
		let image = NSImage(size: container.bounds.size)
		image.addRepresentation(rep)
		return image
	}

	/// Applies a finished drop onto this view.
	func performDrop(
		of pane: PaneID, from source: RiftView<PaneID>, onto target: RiftDropTarget<PaneID>
	) {
		if source === self {
			guard let layout = paneLayout, let targetPane = target.pane,
				let next = layout.moving(pane, to: targetPane, zone: target.zone)
			else { return }
			setZoom(nil)
			commit(next, reason: .move, animated: true)
			setFocus(pane, notify: true, makeFirstResponder: true)
			return
		}
		guard let content = source.detach(pane, reason: .transferOut) else { return }
		adopt(pane, content: content, beside: target.pane, edge: target.zone.edge ?? .right)
		window?.makeKeyAndOrderFront(nil)
	}

	func tearOut(_ pane: PaneID, at screenPoint: CGPoint) {
		guard let handler = onTearOut, let content = detach(pane, reason: .tearOut) else { return }
		handler(pane, content, screenPoint)
	}

	// MARK: Accessibility

	private func rebuildAccessibility() {
		guard zoomedPane == nil, let layout = paneLayout else {
			dividerElements.removeAll()
			return
		}
		var elements: [UUID: RiftDividerAccessibilityElement] = [:]
		for divider in displayGeometry().dividers {
			let element = dividerElements[divider.splitID] ?? RiftDividerAccessibilityElement()
			element.splitID = divider.splitID
			element.axis = divider.axis
			element.position =
				divider.available > 0 ? Double(divider.leadingLength / divider.available) : 0.5
			if let split = layout.split(withID: divider.splitID) {
				element.label =
					"Divider between \(title(for: split.first.lastPaneID)) and \(title(for: split.second.firstPaneID))"
			}
			element.setAccessibilityHelp("Swipe up or down to resize panes.")
			element.setAccessibilityParent(self)
			element.setAccessibilityFrameInParentSpace(
				divider.hitRect(thickness: configuration.metrics.dividerHitThickness))
			let id = divider.splitID
			element.adjust = { [weak self] step in
				MainActor.assumeIsolated { self?.adjustDivider(id, steps: step) ?? false }
			}
			elements[divider.splitID] = element
		}
		dividerElements = elements
		// Each pane offers actions to swap it with its neighbour in each direction.
		for (id, container) in containers {
			container.setAccessibilityCustomActions(
				[RiftDirection.left, .right, .up, .down].compactMap { direction in
					guard layout.swapNeighbor(of: id, toward: direction, in: bounds, metrics: effectiveMetrics) != nil
					else { return nil }
					let name = "Move \(String(describing: direction).capitalized)"
					return NSAccessibilityCustomAction(name: name) { [weak self] in
						MainActor.assumeIsolated { self?.swap(id, toward: direction) ?? false }
					}
				})
		}
	}

	private func adjustDivider(_ id: UUID, steps: Double) -> Bool {
		guard let layout = paneLayout,
			let divider = layout.geometry(in: bounds, metrics: effectiveMetrics).divider(id)
		else { return false }
		let delta = CGFloat(configuration.keyboardResizeFraction * steps) * divider.available
		guard let next = layout.movingDivider(id, by: delta, in: bounds, metrics: effectiveMetrics),
			next != layout
		else { return false }
		placedDividers.insert(id)
		commit(next, reason: .resize, animated: false)
		return true
	}

	open override func isAccessibilityElement() -> Bool { true }
	open override func accessibilityRole() -> NSAccessibility.Role? { .splitGroup }
	open override func accessibilityLabel() -> String? { "Split layout" }

	open override func accessibilityChildren() -> [Any]? {
		let panes: [Any] = (paneLayout?.paneIDs ?? []).compactMap { id in
			guard let container = containers[id], !container.isHidden else { return nil }
			return container
		}
		return panes + Array(dividerElements.values)
	}

	open override func accessibilitySplitters() -> [Any]? { Array(dividerElements.values) }
}

/// A resolved drop location.
struct RiftDropTarget<PaneID: Hashable & Sendable> {
	/// The pane under the pointer, or `nil` when the view is empty.
	var pane: PaneID?
	var zone: RiftDropZone
	/// Highlight rectangle in the target view's coordinates.
	var indicator: CGRect
}

@MainActor
final class RiftDragTrackingState<PaneID: Hashable & Sendable> {
	var session: RiftPaneDragSession<PaneID>?
}
