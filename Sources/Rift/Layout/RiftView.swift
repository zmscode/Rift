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
	/// The focused pane: one in the tiled layout, or one in a floating layer.
	public var focusedPane: PaneID? {
		get { floatingFocus?.pane ?? focusedStorage }
		set {
			if let newValue, focusFloatingPane(newValue) { return }
			setFocus(newValue, notify: false, makeFirstResponder: false)
		}
	}

	public var configuration: RiftConfiguration {
		didSet { if configuration != oldValue { applyConfiguration() } }
	}
	/// Panes can be dragged only between views that share this identifier.
	public var groupIdentifier = "rift.default"

	/// Creates the content view for a pane the first time it appears.
	public var makePaneView: (PaneID) -> NSView
	/// What a busy pane is doing, as a short phrase ("is still working"). Closing busy panes
	/// (with `close` or `closeOthers`) first shows a confirmation card listing them. `nil`, or
	/// `nil` for every pane, closes straight away.
	public var paneActivity: ((PaneID) -> String?)?
	private lazy var closeConfirmation = RiftCloseConfirmation()

	/// Builds the floating preview shown while a pane is dragged, sized to its fitting size.
	/// `nil` (or returning `nil`) shows a snapshot of the pane instead.
	public var makeDragPreview: ((PaneID) -> NSView?)?
	/// Buttons for a pane's header (with `showsPaneHeaders`), at its trailing edge.
	public var paneActions: ((PaneID) -> [RiftPaneHeaderAction])? {
		didSet { refreshHeaderExtras() }
	}
	/// The menu shown on a right-click in a pane's header or top strip.
	public var paneMenu: ((PaneID) -> NSMenu?)? { didSet { refreshHeaderExtras() } }
	/// Renaming: clicking the title of the focused pane (in a window that has been key for a
	/// moment, and without dragging) edits it in place, and Return calls this.
	public var onRenamePane: ((PaneID, String) -> Void)?
	/// The pane under the pointer (`nil` when it is over none, or over a floating layer above).
	public private(set) var hoveredPane: PaneID? {
		didSet { if hoveredPane != oldValue { onHoverChange?(hoveredPane) } }
	}
	/// Called when the pointer moves onto another pane (or off them all).
	public var onHoverChange: ((PaneID?) -> Void)?
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
	/// Called when a layout change has finished moving (right away for an unanimated change).
	public var onLayoutSettled: (() -> Void)?

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
	private var presentationObservers: [PaneID: [RiftWeakPresentationObserver]] = [:]
	/// Panes laid out behind the zoomed pane, drawn at `displayedFadeOpacity`.
	private var fadedPanes = Set<PaneID>()
	private var displayedFadeOpacity: Double = 1
	/// Divider lines as drawn now (rect and opacity), and the opacity of all of them together.
	private var dividerState: [UUID: (rect: CGRect, opacity: Double)] = [:]
	private var dividerLineOpacity: Double = 1
	private var zoomFractions: [PaneID: CGFloat] = [:]
	/// Panes still growing out of an edge, and how far they have got.
	private var growthState: [PaneID: (transition: RiftGrowthTransition, progress: Double)] = [:]
	private let windowSurfaceView = RiftWindowSurfaceView()
	/// Room for the window buttons reported by a sidebar this view sits in.
	private var sidebarChrome: RiftSidebarChrome?
	/// Title room per pane: leading and trailing insets and the button-row height.
	private var titleRooms: [PaneID: (leading: CGFloat, trailing: CGFloat, row: CGFloat?)] = [:]
	private lazy var dropOverlay = RiftDropOverlayWindow()
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

	// MARK: Floating state

	/// Floating layers, back to front.
	var floating: [RiftFloatingLayer<PaneID>] = []
	var floatingViews: [UUID: RiftFloatingLayerView<PaneID>] = [:]
	var floatingCapsules: [UUID: RiftFloatingCapsule] = [:]
	/// The focused floating pane, when focus is in a floating layer.
	var floatingFocus: (layer: UUID, pane: PaneID)?
	/// The tiled pane that had focus before a floating pane took it (focus returns there).
	var tiledFocusBeforeFloating: PaneID?
	/// The focused tiled pane, ignoring floating focus.
	var tiledFocus: PaneID? { focusedStorage }
	/// A move or resize in progress: the layer, its frame when it started, and the edges.
	var floatingInteraction: (layer: UUID, start: CGRect, edges: RiftResizeEdges?)?
	/// Called when floating layers change (moves, resizes, panes moving in or out, minimising).
	public var onFloatingLayersChange: (([RiftFloatingLayer<PaneID>]) -> Void)?

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
		windowSurfaceView.frame = bounds
		windowSurfaceView.autoresizingMask = [.width, .height]
		addSubview(windowSurfaceView)
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
	public func contentView(for pane: PaneID) -> NSView? {
		containers[pane]?.contentView ?? floatingContentView(for: pane)
	}

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
		accessibilityNeedsRebuild()
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
		container.header.menuProvider = { [weak self] in self?.paneMenu?(id) }
		container.strip.menuProvider = { [weak self] in self?.paneMenu?(id) }
		container.header.actions = paneActions?(id) ?? []
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
		applySurface(to: container)
	}

	/// Builds (when the provider changed) and updates a pane's surface, and sets its content alpha.
	private func applySurface(to container: RiftPaneContainerView) {
		var provider = configuration.paneSurface?.provider
		// A theme tints the built-in surfaces with its canvas colour.
		if let theme = configuration.theme, let surfaces = provider as? RiftPaneSurfaces {
			provider = surfaces.themed(theme)
		}
		if let surfaces = provider as? RiftPaneSurfaces {
			if container.surfaceSource != surfaces || container.surfaceView == nil {
				container.setSurfaceView(surfaces.makeSurfaceView())
				container.surfaceSource = surfaces
				container.hasCustomSurface = false
			}
		} else if let provider {
			if !container.hasCustomSurface {
				container.setSurfaceView(provider.makeSurfaceView())
				container.surfaceSource = nil
				container.hasCustomSurface = true
			}
		} else if container.surfaceView != nil {
			container.setSurfaceView(nil)
			container.surfaceSource = nil
			container.hasCustomSurface = false
		}
		let key = window?.isKeyWindow ?? true
		let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let id = containers.first(where: { $0.value === container })?.key
		let focused = id != nil && id == focusedStorage
		// The inactive fade mode decides what an unfocused pane loses: its surface look, its
		// content opacity, or both.
		let fade = configuration.inactivePaneFade
		if let provider, let surface = container.surfaceView {
			provider.update(
				surface,
				for: RiftPaneSurfaceState(
					isFocused: focused || !fade.fadesStyling, isWindowActive: key, isDark: dark))
		}
		func opacity(_ isFocused: Bool) -> CGFloat? {
			provider?.contentOpacity(
				for: RiftPaneSurfaceState(isFocused: isFocused, isWindowActive: key, isDark: dark))
		}
		container.activeAlpha =
			opacity(true) ?? (key ? 1 : configuration.inactiveWindowFocusedPaneAlpha)
		container.inactiveAlpha =
			fade.fadesText
			? opacity(false)
				?? (key ? configuration.inactivePaneAlpha : configuration.inactiveWindowPaneAlpha)
			: container.activeAlpha
	}

	private func applyFocusBorderStyle() {
		let base =
			(configuration.focusBorderColor
			?? themedPalette.color(configuration.focusBorderPreset))
			.withAlphaComponent(configuration.focusBorderOpacity)
		let active = window?.isKeyWindow ?? true
		let color =
			active
			? base
			: base.withAlphaComponent(
				base.alphaComponent * configuration.inactiveWindowFocusBorderOpacity)
		var gradient: [NSColor]?
		if configuration.focusBorderUsesGradient {
			effectiveAppearance.performAsCurrentDrawingAppearance {
				gradient = color.rift_borderGradient()
			}
		}
		for overlay in [focusOverlay, departingFocusOverlay] {
			overlay.isEnabled = configuration.showsFocusBorder
			overlay.color = color
			overlay.gradientColors = gradient
			overlay.gradientAngle = configuration.focusBorderGradientAngle
			overlay.lineWidth = configuration.focusBorderWidth
			overlay.cornerRadii = borderRadii(for: overlay.frame)
		}
	}

	private func applyConfiguration() {
		containers.values.forEach(applyConfiguration(to:))
		let dropColor =
			configuration.dropIndicatorColor
			?? configuration.theme.map { NSColor.rift(.accent, in: $0) }
		dropIndicator.color = dropColor
		dropIndicator.cornerRadius = configuration.dropIndicatorCornerRadius
		dropOverlay.indicator.color = dropColor
		dropOverlay.indicator.cornerRadius = configuration.dropIndicatorCornerRadius
		windowSurfaceView.surface =
			configuration.theme.flatMap { theme in
				configuration.windowSurface?.themed(theme)
			} ?? configuration.windowSurface
		applyFocusBorderStyle()
		applyWindowFade()
		updateTrackingArea()
		updateWindowChrome()
		placeContainers(animated: false, added: [])
		needsDisplay = true
	}

	private func title(for id: PaneID) -> String { paneTitle?(id) ?? String(describing: id) }

	private func refreshTitles() {
		for (id, container) in containers { container.header.title = title(for: id) }
		accessibilityNeedsRebuild()
	}

	/// Every pane's frame with the layout tiled, ignoring zoom.
	func tiledGeometry() -> RiftGeometry<PaneID> {
		guard let layout = paneLayout else { return RiftGeometry(bounds: bounds) }
		return layout.geometry(in: bounds, metrics: effectiveMetrics)
	}

	/// Geometry for what can be hit: the whole layout, or only the zoomed pane.
	func displayGeometry() -> RiftGeometry<PaneID> {
		guard paneLayout != nil else { return RiftGeometry(bounds: bounds) }
		if let zoomed = zoomedPane {
			return RiftGeometry(bounds: bounds, paneFrames: [zoomed: bounds])
		}
		return tiledGeometry()
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

	/// Divider lines as drawn: rect and opacity per split.
	private func targetDividerLines(_ geometry: RiftGeometry<PaneID>) -> [UUID: CGRect] {
		guard configuration.showsDividerLines else { return [:] }
		return Dictionary(
			geometry.dividers.map { ($0.splitID, $0.drawnLine) }, uniquingKeysWith: { a, _ in a })
	}

	/// Moves every pane to where the layout puts it, animating with a motion plan: frames move on
	/// the pane curve; new panes pop in or grow out of their edge; panes behind a zoomed pane fade
	/// (`visibility`); divider lines fade in and out one by one; zoom fractions animate.
	private func placeContainers(
		animated: Bool, added: Set<PaneID>, curve curveOverride: RiftMotionCurve? = nil,
		visibility: RiftVisibilityFade.Direction? = nil, elevate: PaneID? = nil
	) {
		let tiled = tiledGeometry()
		var endFrames = tiled.paneFrames
		if let zoomed = zoomedPane { endFrames[zoomed] = bounds }
		let endFaded: Set<PaneID> =
			zoomedPane.map { Set(endFrames.keys).subtracting([$0]) } ?? []
		let endDividers = targetDividerLines(tiled)
		let endLineOpacity: Double = zoomedPane == nil ? 1 : 0
		let endZoom: [PaneID: CGFloat] = zoomedPane.map { [$0: 1] } ?? [:]
		let animate = animated && shouldAnimate
		// A new layout replaces any running layout motion, which continues from where it is now.
		motion.cancel(Self.layoutTrack, finishing: false)
		for (id, container) in containers {
			guard endFrames[id] != nil else {
				container.isHidden = true
				continue
			}
			container.isHidden = false
			container.dragAlpha = draggingPane == id ? 0.35 : 1
		}
		if let elevate, let container = containers[elevate] {
			addSubview(container, positioned: .below, relativeTo: departingFocusOverlay)
		}
		refreshHeaderChrome(endFrames)
		refreshMovementLock()
		guard animate, let curve = curveOverride ?? configuration.animationStyle.paneCurve else {
			growthState = [:]
			for (id, container) in containers {
				guard let frame = endFrames[id] else { continue }
				container.frame = frame
				container.motionAlpha = endFaded.contains(id) ? 0 : 1
				container.isHidden = endFaded.contains(id)
				container.motionPinnedSize = nil
			}
			fadedPanes = endFaded
			displayedFadeOpacity = endFaded.isEmpty ? 1 : 0
			dividerState = endDividers.mapValues { ($0, 1) }
			dividerLineOpacity = endLineOpacity
			renderDividerLines()
			zoomFractions = endZoom
			if runningLayoutAnimations == 0 {
				for id in containers.keys { publishPresentation(for: id, settled: true) }
			}
			syncFocusBorderFrame()
			return
		}

		// The plan.
		var startFrames: [PaneID: CGRect] = [:]
		var growth: [PaneID: RiftGrowthTransition] = [:]
		let usesGrowth = configuration.paneTransition == .edgeGrowth
		for (id, container) in containers {
			guard let end = endFrames[id] else { continue }
			if added.contains(id) {
				if usesGrowth, let layout = paneLayout {
					growth[id] = .inserting(end, from: layout.growthEdge(of: id) ?? .right)
				}
				container.frame = end
				startFrames[id] = end
			} else if let running = growthState[id] {
				// A pane still growing keeps growing from where it is.
				let (t, p) = (running.transition, running.progress)
				growth[id] = RiftGrowthTransition(
					edge: t.edge, startRawFrame: t.rawFrame(progress: p), endRawFrame: end,
					fullExtent: end.rift_extent(along: t.edge),
					startOpacity: t.opacity(progress: p, direction: .insertion),
					startSpatialOpacity: t.spatialOpacity(progress: p))
				startFrames[id] = container.frame
			} else {
				startFrames[id] = container.frame
			}
		}
		if !usesGrowth { containers.filter { added.contains($0.key) }.forEach { popIn($0.value) } }
		let fadeTargets = endFaded.union(fadedPanes)
		let fade = visibility.map {
			RiftVisibilityFade(direction: $0, startOpacity: displayedFadeOpacity)
		}
		let startDividers = dividerState
		let startLineOpacity = dividerLineOpacity
		let startZoom = zoomFractions
		let zoomChanging = Set(startZoom.keys).union(endZoom.keys).filter {
			startZoom[$0] ?? 0 != endZoom[$0] ?? 0
		}
		// Content sizing: hold content at the larger of its start and end size.
		for (id, container) in containers {
			guard let start = startFrames[id], let end = endFrames[id] else { continue }
			let pins =
				configuration.paneContentSizing == .pinnedDuringMotion
				|| (configuration.pinsContentDuringZoom && zoomChanging.contains(id))
			container.motionPinnedSize =
				pins && start != end
				? CGSize(width: max(start.width, end.width), height: max(start.height, end.height))
				: nil
		}
		for id in containers.keys where endFrames[id] != nil {
			publishPresentation(
				for: id, settled: false, target: contentSize(forPaneFrame: endFrames[id]!))
		}

		let timing = RiftMotionTiming(duration: curve.transitionDuration, curve: curve)
		runningLayoutAnimations += 1
		structuralActivity.insert(.structuralTransition)
		let ids = Array(startFrames.keys)
		motion.run(
			Self.layoutTrack, duration: timing.duration,
			apply: { [weak self] elapsed in
				guard let self else { return }
				let p = timing.progress(elapsed: elapsed)
				let fadeOpacity = fade.map { $0.opacity(progress: p) }
				if let fadeOpacity { self.displayedFadeOpacity = fadeOpacity }
				var growing: [PaneID: (RiftGrowthTransition, Double)] = [:]
				for id in ids {
					guard let container = self.containers[id], let start = startFrames[id],
						let end = endFrames[id]
					else { continue }
					var alpha: Double = 1
					if let g = growth[id] {
						container.frame = g.displayFrame(progress: p)
						alpha = g.opacity(progress: p, direction: .insertion)
						growing[id] = (g, p)
					} else {
						container.frame = start.rift_interpolated(to: end, progress: p)
					}
					if fadeTargets.contains(id) {
						alpha *= fadeOpacity ?? (endFaded.contains(id) ? 0 : 1)
					}
					container.motionAlpha = CGFloat(alpha)
				}
				self.growthState = growing.mapValues { (transition: $0.0, progress: $0.1) }
				// Divider lines: rects follow the panes, opacities cross-fade one by one.
				let opacities = riftDividerOpacities(
					from: startDividers.mapValues(\.opacity), to: endDividers.mapValues { _ in 1 },
					progress: p)
				var lines: [UUID: (rect: CGRect, opacity: Double)] = [:]
				for (id, opacity) in opacities {
					let rect: CGRect
					switch (startDividers[id]?.rect, endDividers[id]) {
					case (let a?, let b?): rect = a.rift_interpolated(to: b, progress: p)
					case (let a?, nil): rect = a
					case (nil, let b?): rect = b
					default: continue
					}
					lines[id] = (rect, opacity)
				}
				self.dividerState = lines
				self.dividerLineOpacity =
					fadeOpacity ?? (startLineOpacity + (endLineOpacity - startLineOpacity) * p)
				self.renderDividerLines()
				// Zoom fractions.
				var zooms: [PaneID: CGFloat] = [:]
				for id in zoomChanging {
					let a = startZoom[id] ?? 0
					let b = endZoom[id] ?? 0
					zooms[id] = a + (b - a) * CGFloat(min(max(p, 0), 1))
				}
				self.zoomFractions = endZoom.merging(zooms) { _, new in new }.filter {
					$0.value > 0
				}
				for id in zoomChanging { self.publishPresentation(for: id, settled: false) }
				self.syncFocusBorderFrame()
			},
			completion: { [weak self] in
				guard let self else { return }
				self.growthState = [:]
				self.fadedPanes = endFaded
				self.displayedFadeOpacity = endFaded.isEmpty ? 1 : 0
				for (id, container) in self.containers where endFaded.contains(id) {
					container.isHidden = true
				}
				for container in self.containers.values { container.motionPinnedSize = nil }
				self.dividerState = endDividers.mapValues { ($0, 1) }
				self.dividerLineOpacity = endLineOpacity
				self.renderDividerLines()
				self.zoomFractions = endZoom
				// The layout has settled once the last running motion ends.
				if self.runningLayoutAnimations == 1 {
					for id in self.containers.keys {
						self.publishPresentation(for: id, settled: true)
					}
					self.onLayoutSettled?()
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
		let state = RiftPopState(direction: .entering)
		container.wantsLayer = true
		container.popAlpha = 0
		motion.run(
			ObjectIdentifier(container), duration: state.duration(style: pop),
			apply: { [weak container] elapsed in
				guard let container else { return }
				container.rift_setPresentationScale(
					CGFloat(state.scale(elapsed: elapsed, style: pop)))
				container.popAlpha = CGFloat(state.opacity(elapsed: elapsed, style: pop))
			},
			completion: { [weak container] in
				container?.rift_setPresentationScale(1)
				container?.popAlpha = 1
			})
	}

	open override func didAddSubview(_ subview: NSView) {
		super.didAddSubview(subview)
		if !(subview is RiftFloatingLayerView<PaneID>), !(subview is RiftFloatingCapsule) {
			keepFloatingInFront()
		}
	}

	open override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		layoutFloating()
		placeContainers(animated: false, added: [])
		accessibilityNeedsRebuild()
		window?.invalidateCursorRects(for: self)
	}

	private var accessibilityIsStale = false

	/// The accessibility elements (divider elements, each pane's move actions) are rebuilt when
	/// they are next asked for, or once the changes stop, rather than on every resize frame.
	private func accessibilityNeedsRebuild() {
		accessibilityIsStale = true
		NSObject.cancelPreviousPerformRequests(
			withTarget: self, selector: #selector(rebuildStaleAccessibility), object: nil)
		perform(
			#selector(rebuildStaleAccessibility), with: nil, afterDelay: 0.2,
			inModes: [.common])
	}

	@objc private func rebuildStaleAccessibility() { refreshStaleAccessibility() }

	private func refreshStaleAccessibility() {
		guard accessibilityIsStale else { return }
		accessibilityIsStale = false
		rebuildAccessibility()
	}

	/// Redraws the divider lines at their target places, unless a layout motion is drawing them.
	func refreshDividerLines() {
		guard !motion.isRunning(Self.layoutTrack) else { return renderDividerLines() }
		dividerState = targetDividerLines(tiledGeometry()).mapValues { ($0, 1) }
		dividerLineOpacity = zoomedPane == nil ? 1 : 0
		renderDividerLines()
	}

	private func renderDividerLines() {
		dividerLines.frame = bounds
		let lines = dividerState.values.map {
			(
				rect: dividerLines.convert($0.rect, from: self),
				opacity: CGFloat($0.opacity * dividerLineOpacity)
			)
		}
		dividerLines.show(
			lines, color: themedDividerColor, blendMode: configuration.dividerBlendMode)
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
			layout.removing(.pane(id)) != nil
		else { return false }
		if confirmClose(
			.pane, panes: [id], spotlight: id, perform: { [weak self] in self?.closeNow(id) })
		{
			return true
		}
		return closeNow(id)
	}

	/// Shows the confirmation card when any of `panes` is busy; returns whether it did.
	private func confirmClose(
		_ subject: RiftCloseSubject, panes: [PaneID], spotlight: PaneID,
		perform: @escaping () -> Void
	) -> Bool {
		guard let paneActivity, window != nil else { return false }
		let rows = panes.enumerated().compactMap { index, id -> RiftCloseConfirmation.Row? in
			guard let activity = paneActivity(id) else { return nil }
			return RiftCloseConfirmation.Row(
				id: index, text: "\(title(for: id)) \(activity)",
				goTo: { [weak self] in self?.focus(id) })
		}
		guard !rows.isEmpty else { return false }
		let rect = containers[spotlight]?.frame ?? bounds
		closeConfirmation.present(
			subject: subject, rows: rows, in: self, spotlight: rect, confirm: perform, cancel: {})
		return true
	}

	@discardableResult
	private func closeNow(_ id: PaneID) -> Bool {
		guard let layout = paneLayout, let removal = layout.removing(.pane(id)) else {
			return false
		}
		let wasFocused = focusedStorage == id
		if let container = containers.removeValue(forKey: id) {
			animateOut(container, edge: layout.growthEdge(of: id))
		}
		if wasFocused { focusedStorage = removal.preferredFocus }
		commit(removal.remaining, reason: .close, animated: true)
		if wasFocused { setFocus(removal.preferredFocus, notify: true, makeFirstResponder: true) }
		onPaneClosed?(id)
		return true
	}

	/// Animates a removed pane out, then removes it: it shrinks to the pop-in scale while fading,
	/// or shrinks into the edge it was split from (`edge`) with edge growth.
	private func animateOut(_ container: RiftPaneContainerView, edge: RiftEdge?) {
		guard shouldAnimate, let style = configuration.paneTransitionStyle else {
			container.removeFromSuperview()
			return
		}
		container.wantsLayer = true
		switch style {
		case .popIn(let pop):
			let state = RiftPopState(direction: .leaving)
			motion.run(
				ObjectIdentifier(container), duration: state.duration(style: pop),
				apply: { [weak container] elapsed in
					guard let container else { return }
					container.rift_setPresentationScale(
						CGFloat(state.scale(elapsed: elapsed, style: pop)))
					container.popAlpha = CGFloat(state.opacity(elapsed: elapsed, style: pop))
				},
				completion: { [weak container] in
					container?.removeFromSuperview()
					container?.rift_setPresentationScale(1)
				})
		case .edgeGrowth:
			guard let curve = configuration.animationStyle.paneCurve else {
				container.removeFromSuperview()
				return
			}
			let transition = RiftGrowthTransition.removing(container.frame, into: edge ?? .right)
			let timing = RiftMotionTiming(duration: curve.transitionDuration, curve: curve)
			motion.run(
				ObjectIdentifier(container), duration: timing.duration,
				apply: { [weak container] elapsed in
					guard let container else { return }
					let p = timing.progress(elapsed: elapsed)
					container.frame = transition.displayFrame(progress: p)
					container.popAlpha = CGFloat(
						transition.opacity(progress: p, direction: .removal))
				},
				completion: { [weak container] in container?.removeFromSuperview() })
		}
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
		let others = layout.paneIDs.filter { $0 != keep }
		if confirmClose(
			.otherPanes, panes: others, spotlight: keep,
			perform: { [weak self] in self?.closeOthersNow(keep) })
		{
			return true
		}
		return closeOthersNow(keep)
	}

	@discardableResult
	private func closeOthersNow(_ keep: PaneID) -> Bool {
		guard let layout = paneLayout, layout.contains(keep), layout.paneCount > 1 else {
			return false
		}
		let closed = layout.paneIDs.filter { $0 != keep }
		for id in closed {
			if let container = containers.removeValue(forKey: id) {
				animateOut(container, edge: layout.growthEdge(of: id))
			}
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
		let previous = zoomedPane
		zoomedPane = target
		if let target { setFocus(target, notify: true, makeFirstResponder: true) }
		// The zooming pane is drawn above the others; they stay laid out behind it and fade.
		placeContainers(
			animated: true, added: [], curve: configuration.animationStyle.chromeCurve,
			visibility: target != nil ? .hiding : .revealing, elevate: target ?? previous)
		accessibilityNeedsRebuild()
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
		// Focusing a tiled pane takes focus out of the floating layers.
		if target != nil, floatingFocus != nil { clearFloatingFocus() }
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
		applyWindowFade()
		updateFocusBorder(animated: true)
	}

	/// Moves the focus border to the focused pane, gliding or crossfading when it changes pane.
	private func updateFocusBorder(animated: Bool) {
		defer { updateBorderShape() }
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
		let transition =
			shouldAnimate && animated && moved ? configuration.focusBorderTransition : .off
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
					self.updateBorderShape()
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
			configuration.showsPaneHeaders
			? configuration.headerHeight : configuration.headerlessTopInset
		return CGSize(width: frame.width, height: max(0, frame.height - top))
	}

	/// Also tells `observer` about `pane`'s presentation changes (held weakly).
	public func addPresentationObserver(_ observer: RiftPanePresentationObserving, for pane: PaneID)
	{
		var list = presentationObservers[pane, default: []].filter { $0.observer != nil }
		guard !list.contains(where: { $0.observer === observer }) else { return }
		list.append(RiftWeakPresentationObserver(observer))
		presentationObservers[pane] = list
		if let presentation = presentations[pane] {
			observer.riftPanePresentationDidChange(presentation)
		}
	}

	public func removePresentationObserver(
		_ observer: RiftPanePresentationObserving, for pane: PaneID
	) {
		presentationObservers[pane]?.removeAll { $0.observer == nil || $0.observer === observer }
	}

	/// The presentation of a pane right now.
	public func presentation(of pane: PaneID) -> RiftPanePresentation? { presentations[pane] }

	/// Tells the pane's content (if it adopts `RiftPanePresentationObserving`) and the registered
	/// observers about a change, if there is one.
	private func publishPresentation(for id: PaneID, settled: Bool, target: CGSize? = nil) {
		guard let container = containers[id] else { return }
		let content = container.contentView.frame.size
		let clip = container.contentClip.bounds.size
		let pinned = container.pinnedPaneSize != nil
		let previousTarget = presentations[id].flatMap { $0.isLayoutSettled ? nil : $0.targetSize }
		var presentation = RiftPanePresentation(
			isLayoutSettled: settled, zoomFraction: zoomFractions[id] ?? 0, contentSize: content,
			targetSize: settled ? nil : (target ?? previousTarget),
			contentWidth: pinned ? content.width : nil,
			hiddenTrailingWidth: max(0, content.width - clip.width),
			surfaceSize: container.frame.size)
		if let room = titleRooms[id] {
			presentation.titleLeadingInset = room.leading
			presentation.titleTrailingInset = room.trailing
			presentation.titleRowHeight = room.row
		}
		guard presentations[id] != presentation else { return }
		presentations[id] = presentation
		(container.contentView as? RiftPanePresentationObserving)?.riftPanePresentationDidChange(
			presentation)
		for box in presentationObservers[id] ?? [] {
			box.observer?.riftPanePresentationDidChange(presentation)
		}
	}

	/// Surfaces and content alpha for the focus, window key state and appearance.
	private func applyWindowFade() {
		containers.values.forEach(applySurface(to:))
		windowSurfaceView.isWindowActive = window?.isKeyWindow ?? true
	}

	open override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		applyWindowFade()
	}

	/// Hides (or restores) the scrollers inside the panes while anything reshapes them. Views that
	/// adopt `RiftScrollerSuppressing` hide their own; other scroll views' `NSScroller`s are faded.
	private var suppressedScrollers: [ObjectIdentifier: (NSScroller, CGFloat)] = [:]
	private var suppressingViews: [ObjectIdentifier: RiftScrollerSuppressing] = [:]
	private func updateScrollerSuppression() {
		if structuralActivity.isEmpty || !configuration.hidesScrollersDuringStructuralChanges {
			for (scroller, alpha) in suppressedScrollers.values { scroller.alphaValue = alpha }
			suppressedScrollers.removeAll()
			for view in suppressingViews.values { view.riftSetScrollersSuppressed(false) }
			suppressingViews.removeAll()
			return
		}
		func visit(_ view: NSView) {
			if let adopter = view as? RiftScrollerSuppressing {
				if suppressingViews[ObjectIdentifier(view)] == nil {
					suppressingViews[ObjectIdentifier(view)] = adopter
					adopter.riftSetScrollersSuppressed(true)
				}
				return
			}
			if let scrollView = view as? NSScrollView {
				for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller]
					.compactMap({ $0 }) where suppressedScrollers[ObjectIdentifier(scroller)] == nil
				{
					suppressedScrollers[ObjectIdentifier(scroller)] = (
						scroller, scroller.alphaValue
					)
					scroller.alphaValue = 0
				}
			}
			view.subviews.forEach(visit)
		}
		containers.values.forEach { visit($0.contentView) }
	}

	/// Keeps the focus border on the focused pane while panes move (a glide tracks it itself).
	private func syncFocusBorderFrame() {
		defer { updateBorderShape() }
		guard !borderGlides, let pane = borderPane, let target = containers[pane] else { return }
		focusOverlay.frame = target.frame
		if target.isHidden { updateFocusBorder(animated: false) }
	}

	/// The border presets' colours: the theme's when there is one, else `colorPalette`.
	private var themedPalette: RiftColorPalette {
		configuration.theme.map { RiftColorPalette(theme: $0) } ?? configuration.colorPalette
	}

	/// Divider lines take the theme's text colour at the configured colour's opacity.
	private var themedDividerColor: NSColor {
		guard let theme = configuration.theme else { return configuration.dividerColor }
		let base = configuration.dividerColor
		return NSColor(name: nil) { appearance in
			var alpha: CGFloat = 1
			appearance.performAsCurrentDrawingAppearance {
				alpha = base.usingColorSpace(.sRGB)?.alphaComponent ?? 1
			}
			let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
			return NSColor(rift: theme.theme(isDark: dark)[.content]).withAlphaComponent(alpha)
		}
	}

	/// Per-corner radii for a border at `frame`: the pane radius, except corners that meet the
	/// window's corners, which take `layoutCornerRadius`.
	private func borderRadii(for frame: CGRect) -> RiftCornerRadii {
		let pane = configuration.paneCornerRadius
		guard configuration.focusBorderFollowsWindowCorners,
			let outer = configuration.layoutCornerRadius
		else { return RiftCornerRadii(pane) }
		// Compare against the window's content area when there is one, else this view.
		let container: CGRect
		let rect: CGRect
		if let content = window?.contentView {
			container = content.bounds
			rect = content.convert(frame, from: self)
		} else {
			container = bounds
			rect = frame
		}
		let tolerance: CGFloat = 0.5
		let left = abs(rect.minX - container.minX) < tolerance
		let right = abs(rect.maxX - container.maxX) < tolerance
		let flipped = window?.contentView?.isFlipped ?? isFlipped
		let atMinY = abs(rect.minY - container.minY) < tolerance
		let atMaxY = abs(rect.maxY - container.maxY) < tolerance
		let top = flipped ? atMinY : atMaxY
		let bottom = flipped ? atMaxY : atMinY
		return RiftCornerRadii(
			topLeft: left && top ? outer : pane, topRight: right && top ? outer : pane,
			bottomLeft: left && bottom ? outer : pane, bottomRight: right && bottom ? outer : pane)
	}

	/// Corner radii of the border and the divider cover follow the border's frame.
	private func updateBorderShape() {
		focusOverlay.cornerRadii = borderRadii(for: focusOverlay.frame)
		departingFocusOverlay.cornerRadii = borderRadii(for: departingFocusOverlay.frame)
		let covers =
			configuration.focusBorderCoversDividers && configuration.showsFocusBorder
			&& !focusOverlay.isHidden
		// Lines are centred on the pane edge, so the cover reaches half a line past the frame.
		let metrics = configuration.metrics
		let half = (metrics.lineThickness ?? metrics.dividerThickness) / 2
		let rect = focusOverlay.frame.insetBy(dx: -half, dy: -half)
		dividerLines.cover(
			covers ? dividerLines.convert(rect, from: self) : nil,
			radii: focusOverlay.cornerRadii, inset: configuration.focusBorderWidth + half)
	}

	open override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if let monitor = cursorMonitor {
			NSEvent.removeMonitor(monitor)
			cursorMonitor = nil
		}
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
		// The resize cursor over a divider is set on every mouse move, and again on the next turn
		// of the run loop, so it wins over pane content that sets its own cursor in between.
		window?.acceptsMouseMovedEvents = true
		cursorMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
			[weak self] event in
			MainActor.assumeIsolated { self?.updateDividerCursor(for: event) }
			return event
		}
		placeContainers(animated: false, added: [])
		updateTrackingArea()
	}

	private var cursorMonitor: Any?
	private var showsDividerCursor = false

	/// The divider under a window point, if this view is what the mouse would hit there (nothing
	/// floating or overlaid above it).
	private func hoveredDivider(at windowPoint: CGPoint) -> (hit: RiftDividerHit, point: CGPoint)? {
		guard let window, !isHiddenOrHasHiddenAncestor, dividerDrag == nil else { return nil }
		let point = convert(windowPoint, from: nil)
		guard bounds.contains(point), let hit = dividerHit(at: point),
			let content = window.contentView,
			content.hitTest(content.superview?.convert(windowPoint, from: nil) ?? windowPoint)
				=== self
		else { return nil }
		return (hit, point)
	}

	private func updateDividerCursor(for event: NSEvent) {
		guard event.window === window, window != nil else { return }
		guard let hovered = hoveredDivider(at: event.locationInWindow) else {
			if showsDividerCursor {
				// Off the divider: hand the cursor back to whatever is under the pointer.
				showsDividerCursor = false
				if dividerDrag == nil {
					NSCursor.arrow.set()
					window?.invalidateCursorRects(for: self)
				}
			}
			return
		}
		showsDividerCursor = true
		cursor(for: hovered.hit, at: hovered.point).set()
		DispatchQueue.main.async { [weak self] in
			guard let self, let window = self.window,
				let hovered = self.hoveredDivider(at: window.mouseLocationOutsideOfEventStream)
			else { return }
			self.cursor(for: hovered.hit, at: hovered.point).set()
		}
	}

	open override func cursorUpdate(with event: NSEvent) {
		guard let hovered = hoveredDivider(at: event.locationInWindow) else {
			return super.cursorUpdate(with: event)
		}
		cursor(for: hovered.hit, at: hovered.point).set()
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
					(note.userInfo?[RiftContainerAnimation.widthChangeKey] as? NSNumber)?
					.doubleValue
				let contentWidth =
					(note.userInfo?[RiftContainerAnimation.contentWidthKey] as? NSNumber)?
					.doubleValue
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
			for (id, frame) in layout.geometry(in: targetBounds, metrics: effectiveMetrics)
				.paneFrames
			{
				sizes[id] = frame.size
			}
		}
		// Hold each pane's content at the larger of the size it has now and the size it will end
		// at, so it reflows at most once and never leaves part of its pane uncovered: a shrinking
		// pane clips its content, a growing pane reveals it. A begin that interrupts another only
		// ever grows the held size.
		for (id, container) in containers {
			guard let target = sizes[id] else { continue }
			let current = container.containerPinnedSize ?? container.bounds.size
			sizes[id] = CGSize(
				width: max(target.width, current.width), height: max(target.height, current.height))
		}
		containerAnimationPaneSizes = sizes
		for (id, container) in containers { container.containerPinnedSize = sizes[id] }
	}

	private func containerAnimationDidEnd(object: ObjectIdentifier?) {
		guard isOwnWindow(object), containerAnimationPaneSizes != nil else { return }
		containerAnimationPaneSizes = nil
		for container in containers.values { container.containerPinnedSize = nil }
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
			}
			headlessWindow?.rowHeight = configuration.headerHeight
			headlessWindow?.titlebarHeight = configuration.titlebarMetrics?.height
			headlessWindow?.horizontalOffset = configuration.titlebarMetrics?.buttonOffset.x ?? 0
			headlessWindow?.verticalOffset = configuration.titlebarMetrics?.buttonOffset.y ?? 0
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
		if headless || sidebarChrome != nil, let window,
			let contentHeight = window.contentView?.bounds.height
		{
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
			var trailingClearance: CGFloat = 0
			if touchesTop, let chrome = sidebarChrome {
				// A sidebar says how much room to keep, measured from this layout's edges.
				if frame.minX <= bounds.minX + 0.5 { clearance = chrome.leadingButtonRoom }
				if frame.maxX >= bounds.maxX - 0.5 { trailingClearance = chrome.trailingButtonRoom }
			} else if touchesTop, let buttons, buttons.maxX > frame.minX, buttons.minX < frame.maxX
			{
				let reserved =
					configuration.windowButtonInset.map {
						convert(CGPoint(x: $0, y: 0), from: nil).x
					}
					?? buttons.maxX + configuration.windowButtonSpacing
				clearance = max(0, reserved - frame.minX)
			}
			container.header.leadingInset = max(0, clearance - 6)
			container.header.trailingInset = trailingClearance
			// Pane content lays its own title out in the same room, on the window buttons' line.
			let row = touchesTop ? buttons.map { 2 * ($0.midY - frame.minY) } : nil
			let room = (leading: clearance, trailing: trailingClearance, row: row)
			if titleRooms[id].map({ $0 != room }) ?? true {
				titleRooms[id] = room
				let current = presentations[id]
				publishPresentation(
					for: id, settled: current?.isLayoutSettled ?? true, target: current?.targetSize)
			}
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
		// A click on the focused pane's title, in a window that was already key (not the click
		// that activated it, nor within a double-click of it), arms a rename.
		let sinceFirstMouse = header?.firstMouseTimestamp.map { event.timestamp - $0 } ?? .infinity
		let armsRename =
			onRenamePane != nil && focusedPane == pane && event.clickCount == 1
			&& (window?.isKeyWindow ?? false) && NSApp.isActive
			&& sinceFirstMouse > NSEvent.doubleClickInterval
			&& (header?.titleContains(windowPoint: event.locationInWindow) ?? false)
		let start = NSEvent.mouseLocation
		if headerMovesWindow, !event.modifierFlags.contains(.option) {
			beginWindowDrag(from: pane, with: event)
		} else {
			trackPaneDrag(pane, startingWith: event)
		}
		// Both of those return once the button is up: a press that didn't move is a click.
		let end = NSEvent.mouseLocation
		guard armsRename, hypot(end.x - start.x, end.y - start.y) < 3, let header else { return }
		header.beginRenaming { [weak self] title in self?.onRenamePane?(pane, title) }
	}

	/// Re-reads every header's actions (after `paneActions` changes).
	public func refreshHeaderExtras() {
		for (id, container) in containers { container.header.actions = paneActions?(id) ?? [] }
		for view in floatingViews.values {
			view.content.paneActions = paneActions
			view.content.paneMenu = paneMenu
			view.content.onRenamePane = onRenamePane
		}
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
			options: [
				.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect,
			],
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
		hoveredPane = nil
	}

	/// The tiled pane under a window point, unless a floating layer covers it.
	private func updateHover(_ windowPoint: CGPoint) {
		let point = convert(windowPoint, from: nil)
		let covered = floating.contains {
			!$0.isMinimised && (floatingViews[$0.id]?.frame.contains(point) ?? false)
		}
		hoveredPane = covered || !bounds.contains(point) ? nil : displayGeometry().pane(at: point)
	}

	open override func mouseMoved(with event: NSEvent) {
		super.mouseMoved(with: event)
		isHoverLockSuspended = false
		refreshMovementLock()
		updateHover(event.locationInWindow)
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
		// Floating layers (and their capsules) sit above the tiled panes and their dividers.
		if let hit = floatingHitTest(point) { return hit }
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
		_ pane: PaneID, startingWith event: NSEvent,
		replayingClicksThrough replayView: RiftPaneDragStripView?
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
		// A floating layer covers the tiled panes under it.
		if floating.contains(where: {
			!$0.isMinimised && (floatingViews[$0.id]?.frame.contains(point) ?? false)
		}) {
			return nil
		}
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
		if configuration.dropIndicatorUsesChildWindow, let window {
			// A child window above this one, so the highlight draws over glass and every view.
			dropIndicator.isHidden = true
			dropOverlay.show(
				rect.map { window.convertToScreen(convert($0, to: nil)) },
				above: rect == nil ? nil : window)
			return
		}
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
		if let previous = draggingPane { containers[previous]?.dragAlpha = 1 }
		draggingPane = pane
		if let pane { containers[pane]?.dragAlpha = 0.35 }
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
		refreshStaleAccessibility()
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
					guard
						layout.swapNeighbor(
							of: id, toward: direction, in: bounds, metrics: effectiveMetrics) != nil
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
		refreshStaleAccessibility()
		let panes: [Any] = (paneLayout?.paneIDs ?? []).compactMap { id in
			guard let container = containers[id], !container.isHidden else { return nil }
			return container
		}
		return panes + Array(dividerElements.values)
	}

	open override func accessibilitySplitters() -> [Any]? {
		refreshStaleAccessibility()
		return Array(dividerElements.values)
	}
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

extension RiftView: RiftSidebarChromeObserving {
	public func riftSidebarChromeDidChange(_ chrome: RiftSidebarChrome) {
		guard chrome != sidebarChrome else { return }
		sidebarChrome = chrome
		refreshHeaderChrome()
	}
}
