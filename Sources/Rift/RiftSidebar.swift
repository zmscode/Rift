import AppKit
import RiftCore

/// What a sidebar tells the layouts inside its content: how much room their pane headers keep for
/// the window buttons (and the sidebar's toggle button) at the leading and trailing edges.
public struct RiftSidebarChrome: Equatable, Sendable {
	public var position: RiftSidebarPosition
	/// 0 with the sidebar open, 1 folded, in between while it folds.
	public var collapseProgress: CGFloat
	public var isFullScreen: Bool
	public var leadingButtonRoom: CGFloat
	public var trailingButtonRoom: CGFloat
}

/// Adopted by views inside a sidebar's content that want to hear about its chrome (`RiftView`
/// does, and keeps that room clear in the headers of panes along the top).
@MainActor
public protocol RiftSidebarChromeObserving: AnyObject {
	func riftSidebarChromeDidChange(_ chrome: RiftSidebarChrome)
}

/// A window-level container with a sidebar beside the content.
///
/// - The sidebar sits on the left or right, `width` wide (167pt up to 60% of the container, at most
///   480pt), and can be resized by dragging its inner edge.
/// - It folds away with the toggle button (28×28, beside the window buttons), `toggleSidebar()`,
///   or a two-finger swipe toward its side. Folding runs on the chrome curve: the sidebar stays in
///   place and is revealed or covered by a mask while the content slides over it.
/// - Unless `preservesWindowWidth` is set, folding shrinks the window by the sidebar's width (never
///   below 480pt, or 720pt minus the sidebar) and unfolding grows it back, so the content keeps its
///   size. Otherwise the content takes the space, and any `RiftView` inside hears about the width
///   change before it starts (see `RiftContainerAnimation`).
/// - Layouts inside (`RiftSidebarChromeObserving`) keep room for the window buttons as it folds.
open class RiftSidebarContainerView: NSView {
	public let sidebarView: NSView
	public let contentView: NSView

	public var position: RiftSidebarPosition = .left { didSet { relayout() } }
	public var density: RiftChromeDensity = .comfortable { didSet { relayout() } }
	/// The sidebar's width when open.
	public var width: CGFloat = RiftSidebarMath.defaultWidth {
		didSet {
			let clamped = RiftSidebarMath.clampedWidth(width, containerWidth: bounds.width)
			if clamped != width { width = clamped } else { relayout() }
		}
	}
	public private(set) var isCollapsed = false
	/// Keep the window's width when folding; the content takes the space instead.
	public var preservesWindowWidth = false
	/// The curve folds run on (`nil` folds at once). Reduce Motion folds at once too.
	public var foldCurve: RiftMotionCurve? = RiftAnimationStyle.snappy.chromeCurve
	public var swipe: RiftSidebarSwipe = .swipe
	public var hidesToggleButton = false { didSet { relayout() } }
	/// Keep the window from being resized narrower than `windowMinimumWidth` (and widen it if it
	/// already is).
	public var managesWindowMinimumWidth = true { didSet { applyWindowMinimumWidth() } }
	/// The colour of the line between the sidebar and the content in compact density.
	public var dividerColor: NSColor = NSColor(name: nil) { appearance in
		appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
			? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1)
	} { didSet { relayout() } }

	/// The user picked a side or a density from the toggle button's menu (right-click it).
	public var onPositionChange: ((RiftSidebarPosition) -> Void)?
	public var onDensityChange: ((RiftChromeDensity) -> Void)?
	/// `windowMinimumWidth` changed.
	public var onWindowMinimumWidthChange: ((CGFloat) -> Void)?

	/// The user folded or unfolded the sidebar (toggle, swipe).
	public var onCollapsedChange: ((Bool) -> Void)?
	/// The user resized the sidebar.
	public var onWidthChange: ((CGFloat) -> Void)?
	/// The fold progress, 0 open … 1 folded, on every frame of a fold.
	public var onCollapseProgressChange: ((CGFloat) -> Void)?

	/// 0 with the sidebar open, 1 folded.
	public private(set) var collapseProgress: CGFloat = 0 {
		didSet {
			guard collapseProgress != oldValue else { return }
			onCollapseProgressChange?(collapseProgress)
		}
	}
	/// The smallest the window should be: 720pt open, less once a fold has shrunk it.
	public private(set) var windowMinimumWidth: CGFloat = RiftSidebarMath.expandedWindowMinimumWidth {
		didSet {
			guard windowMinimumWidth != oldValue else { return }
			onWindowMinimumWidthChange?(windowMinimumWidth)
		}
	}
	private let dividerLine = CALayer()

	public let toggleButton = RiftChromeIconButton()
	private let resizeHandle = RiftSidebarResizeHandle()
	private let revealMask = CALayer()
	private lazy var motion = RiftMotionDriver(view: self)
	private var collapsedWindowShrink: CGFloat = 0
	private var swipeMonitor: Any?
	private var swipeTravel = CGSize.zero
	private var isTrackingSwipe = false
	private var hasRecognizedSwipe = false
	private var fullScreenObservers: [NSObjectProtocol] = []
	private var isFullScreen = false { didSet { if isFullScreen != oldValue { relayout() } } }
	private var announcedFold = false
	private static var foldTrack: AnyHashable { "rift.sidebarFold" }

	public init(sidebar: NSView, content: NSView) {
		sidebarView = sidebar
		contentView = content
		super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
		wantsLayer = true
		layer?.backgroundColor = NSColor.clear.cgColor
		sidebar.wantsLayer = true
		addSubview(sidebar)
		revealMask.anchorPoint = .zero
		revealMask.backgroundColor = NSColor.black.cgColor
		sidebar.layer?.mask = revealMask
		content.wantsLayer = true
		addSubview(content)
		resizeHandle.onDrag = { [weak self] x in self?.dragResize(to: x) }
		resizeHandle.onDragEnd = { [weak self] in
			guard let self else { return }
			self.onWidthChange?(self.width)
		}
		addSubview(resizeHandle)
		toggleButton.menuProvider = { [weak self] in
			guard let self, self.onPositionChange != nil || self.onDensityChange != nil else { return nil }
			return self.makeToggleMenu()
		}
		toggleButton.target = self
		toggleButton.action = #selector(toggleSidebar)
		addSubview(toggleButton)
		relayout()
	}

	@available(*, unavailable)
	public required init?(coder: NSCoder) {
		fatalError("RiftSidebarContainerView does not support NSCoder")
	}

	open override var isFlipped: Bool { true }

	// MARK: Folding

	@objc public func toggleSidebar() { setCollapsed(!isCollapsed, animated: true, byUser: true) }

	/// Folds or unfolds the sidebar.
	public func setCollapsed(_ collapsed: Bool, animated: Bool = true) {
		setCollapsed(collapsed, animated: animated, byUser: false)
	}

	private func setCollapsed(_ collapsed: Bool, animated: Bool, byUser: Bool) {
		guard collapsed != isCollapsed else { return }
		isCollapsed = collapsed
		if byUser { onCollapsedChange?(collapsed) }
		let start = collapseProgress
		let end: CGFloat = collapsed ? 1 : 0
		let visible = width
		// How much the window changes: shrink when folding (if it may), grow back by the same.
		var windowChange: CGFloat = 0
		// A window that (nearly) fills its screen keeps its width, like `preservesWindowWidth`.
		let fillsScreen =
			window.flatMap { window in
				window.screen.map {
					RiftSidebarMath.windowFillsScreen(
						windowFrame: window.frame, screenFrame: $0.visibleFrame)
				}
			} ?? false
		if collapsed, preservesWindowWidth || isFullScreen || fillsScreen {
			collapsedWindowShrink = 0
		} else if !preservesWindowWidth, !isFullScreen, let window {
			if collapsed {
				collapsedWindowShrink = RiftSidebarMath.collapsedWindowShrink(
					windowWidth: window.frame.width, sidebarWidth: visible)
				windowChange = -collapsedWindowShrink
			} else {
				windowChange = collapsedWindowShrink
				collapsedWindowShrink = 0
			}
		}
		windowMinimumWidth =
			collapsed
			? RiftSidebarMath.collapsedWindowMinimumWidth(shrink: collapsedWindowShrink)
			: RiftSidebarMath.expandedWindowMinimumWidth
		// The content's width changes by the part of the sidebar the window doesn't absorb.
		let contentChange = visible * (end - start) + windowChange
		let startFrame = window?.frame
		let targetFrame = startFrame.map { frame -> CGRect in
			var target = frame
			target.size.width += windowChange
			// A left sidebar folds from the window's left edge, so the content stays put on screen.
			if position == .left { target.origin.x -= windowChange }
			if let screen = window?.screen?.visibleFrame {
				target.size.width = min(target.width, screen.width)
				target.origin.x = min(max(target.minX, screen.minX), screen.maxX - target.width)
			}
			return target
		}
		// No animation with Reduce Motion, or while nobody can see the window.
		let isWatched =
			window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
		let curve =
			NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !animated || !isWatched
			? nil : foldCurve
		motion.cancel(Self.foldTrack, finishing: false)
		// While it unfolds the sidebar is fully opaque; it fades away once folded.
		if !collapsed {
			sidebarView.animator().alphaValue = 1
			sidebarView.alphaValue = 1
		}
		// The window may be as narrow as the fold leaves it before it gets there.
		if collapsed { applyWindowMinimumWidth() }
		announceFold(contentChange: contentChange)
		guard let curve, window != nil else {
			if let targetFrame, windowChange != 0 { window?.setFrame(targetFrame, display: true) }
			collapseProgress = end
			relayout()
			finishFold(animated: false)
			return
		}
		let timing = RiftMotionTiming(
			duration: RiftSidebarMath.foldDuration(curve: curve), curve: curve)
		motion.run(
			Self.foldTrack, duration: timing.duration,
			apply: { [weak self] elapsed in
				guard let self else { return }
				let p = timing.progress(elapsed: elapsed)
				if let startFrame, let targetFrame, windowChange != 0 {
					self.window?.setFrame(
						startFrame.rift_interpolated(to: targetFrame, progress: p), display: true)
				}
				self.collapseProgress = start + (end - start) * CGFloat(p)
				self.relayout()
			},
			completion: { [weak self] in self?.finishFold(animated: true) })
	}

	/// Keeps the window at least `windowMinimumWidth` wide, widening it (within its screen) if it
	/// is narrower.
	private func applyWindowMinimumWidth() {
		guard managesWindowMinimumWidth, let window, !isFullScreen else { return }
		let minimum = windowMinimumWidth
		if window.contentMinSize.width != minimum {
			window.contentMinSize = CGSize(width: minimum, height: window.contentMinSize.height)
		}
		if window.minSize.width != minimum {
			window.minSize = CGSize(width: minimum, height: window.minSize.height)
		}
		guard window.frame.width < minimum, !motion.isRunning(Self.foldTrack) else { return }
		var frame = window.frame
		let growth = minimum - frame.width
		frame.size.width = minimum
		if position == .left { frame.origin.x -= growth }
		if let screen = window.screen?.visibleFrame {
			frame.size.width = min(frame.width, screen.width)
			frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
		}
		window.setFrame(frame, display: true)
	}

	/// Tells layouts in the content that its width is about to change (they hold their content
	/// until the fold ends), when it does.
	private func announceFold(contentChange: CGFloat) {
		guard let window, abs(contentChange) > 0.5 else { return }
		if announcedFold {
			NotificationCenter.default.post(
				name: RiftContainerAnimation.didEndNotification, object: window)
		}
		announcedFold = true
		NotificationCenter.default.post(
			name: RiftContainerAnimation.willBeginNotification, object: window,
			userInfo: [
				RiftContainerAnimation.contentWidthKey: NSNumber(
					value: Double(contentView.bounds.width)),
				RiftContainerAnimation.widthChangeKey: NSNumber(value: Double(contentChange)),
			])
	}

	private func finishFold(animated: Bool) {
		applyWindowMinimumWidth()
		relayout()
		if isCollapsed, collapseProgress >= 1 {
			// The folded sidebar fades out, then is hidden.
			NSAnimationContext.runAnimationGroup { context in
				context.duration = animated ? RiftSidebarMath.fadeOutDuration : 0
				context.timingFunction = CAMediaTimingFunction(name: .easeOut)
				sidebarView.animator().alphaValue = 0
			} completionHandler: { [weak self] in
				MainActor.assumeIsolated {
					guard let self, self.isCollapsed, self.collapseProgress >= 1 else { return }
					self.sidebarView.isHidden = true
				}
			}
		}
		guard announcedFold else { return }
		announcedFold = false
		if let window {
			NotificationCenter.default.post(
				name: RiftContainerAnimation.didEndNotification, object: window)
		}
	}

	// MARK: Toggle menu

	/// The toggle button's right-click menu: which side the sidebar is on, and the density.
	private func makeToggleMenu() -> NSMenu {
		let menu = NSMenu()
		func add(_ title: String, symbol: String, on: Bool, _ action: @escaping () -> Void) {
			let item = RiftClosureMenuItem(title: title, handler: action)
			item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
			item.state = on ? .on : .off
			menu.addItem(item)
		}
		add("Left Side", symbol: "sidebar.leading", on: position == .left) { [weak self] in
			self?.onPositionChange?(.left)
		}
		add("Right Side", symbol: "sidebar.trailing", on: position == .right) { [weak self] in
			self?.onPositionChange?(.right)
		}
		menu.addItem(.separator())
		add("Comfortable", symbol: "rectangle.grid.2x2", on: density == .comfortable) { [weak self] in
			self?.onDensityChange?(.comfortable)
		}
		add("Compact", symbol: "rectangle.split.2x2", on: density == .compact) { [weak self] in
			self?.onDensityChange?(.compact)
		}
		return menu
	}

	// MARK: Layout

	open override func layout() {
		super.layout()
		relayout()
	}

	open override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		relayout()
	}

	private func relayout() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }
		let bounds = self.bounds
		let w = min(width, bounds.width)
		let visible = w * (1 - collapseProgress)
		// The sidebar keeps its width and place; the mask shows the part not yet covered.
		let sidebarX = position == .left ? 0 : bounds.width - w
		sidebarView.frame = CGRect(x: sidebarX, y: 0, width: w, height: bounds.height)
		revealMask.frame =
			position == .left
			? CGRect(x: 0, y: 0, width: visible, height: bounds.height)
			: CGRect(x: w - visible, y: 0, width: visible, height: bounds.height)
		if visible > 0 { sidebarView.isHidden = false }
		// In compact density a hairline separates the sidebar from the panes.
		if dividerLine.superlayer == nil { layer?.addSublayer(dividerLine) }
		dividerLine.zPosition = 10
		dividerLine.isHidden = density != .compact || visible <= 0
		let lineX = position == .left ? visible - 0.5 : bounds.width - visible - 0.5
		dividerLine.frame = CGRect(x: lineX, y: 0, width: 1, height: bounds.height)
		effectiveAppearance.performAsCurrentDrawingAppearance {
			dividerLine.backgroundColor = dividerColor.cgColor
		}
		// Compact panes overlap the sidebar's edge by a point, so the shared line is drawn once.
		let overlap: CGFloat = density == .compact && visible > 0 ? 1 : 0
		let contentWidth = max(0, bounds.width - visible + overlap)
		contentView.frame = CGRect(
			x: position == .left ? visible - overlap : 0, y: 0, width: contentWidth,
			height: bounds.height)
		let edge = position == .left ? visible : bounds.width - visible
		resizeHandle.frame = CGRect(
			x: edge - RiftSidebarMath.resizeHandleWidth / 2, y: 0,
			width: RiftSidebarMath.resizeHandleWidth, height: bounds.height)
		resizeHandle.isHidden = isCollapsed || collapseProgress > 0
		toggleButton.isHidden = hidesToggleButton
		toggleButton.frame = RiftSidebarMath.toggleFrame(
			position: position, containerWidth: bounds.width, isFullScreen: isFullScreen,
			density: density)
		toggleButton.symbolName = position == .left ? "sidebar.left" : "sidebar.right"
		let label = isCollapsed ? "Show Sidebar" : "Hide Sidebar"
		if toggleButton.toolTip != label {
			toggleButton.toolTip = label
			toggleButton.setAccessibilityLabel(label)
		}
		addSubview(toggleButton, positioned: .above, relativeTo: nil)
		publishChrome()
	}

	private var lastChrome: RiftSidebarChrome?
	private func publishChrome() {
		let chrome = RiftSidebarChrome(
			position: position, collapseProgress: collapseProgress, isFullScreen: isFullScreen,
			leadingButtonRoom: RiftSidebarMath.leadingButtonRoom(
				position: position, collapseProgress: collapseProgress, isFullScreen: isFullScreen,
				density: density, hidesToggle: hidesToggleButton),
			trailingButtonRoom: RiftSidebarMath.trailingButtonRoom(
				position: position, collapseProgress: collapseProgress,
				hidesToggle: hidesToggleButton))
		guard chrome != lastChrome else { return }
		lastChrome = chrome
		func visit(_ view: NSView) {
			if let observer = view as? RiftSidebarChromeObserving {
				observer.riftSidebarChromeDidChange(chrome)
				return
			}
			view.subviews.forEach(visit)
		}
		visit(contentView)
	}

	/// Re-sends the chrome to layouts added to the content since.
	public func refreshChrome() {
		lastChrome = nil
		publishChrome()
	}

	private func dragResize(to x: CGFloat) {
		let point = x
		let requested = position == .left ? point : bounds.width - point
		width = RiftSidebarMath.clampedWidth(requested, containerWidth: bounds.width)
	}

	// MARK: Window

	open override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
		fullScreenObservers = []
		if let monitor = swipeMonitor {
			NSEvent.removeMonitor(monitor)
			swipeMonitor = nil
		}
		guard let window else { return }
		isFullScreen = window.styleMask.contains(.fullScreen)
		applyWindowMinimumWidth()
		fullScreenObservers = [
			NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
		]
		.map {
			NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) {
				[weak self] _ in
				MainActor.assumeIsolated {
					self?.isFullScreen = self?.window?.styleMask.contains(.fullScreen) ?? false
				}
			}
		}
		swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
			[weak self] event in
			MainActor.assumeIsolated { self?.handleSwipe(event) ?? false } ? nil : event
		}
		DispatchQueue.main.async { [weak self] in self?.refreshChrome() }
	}

	/// Recognizes a two-finger horizontal swipe. Returns `true` when the event is swallowed.
	private func handleSwipe(_ event: NSEvent) -> Bool {
		guard swipe != .off, let window, event.window === window else { return false }
		guard event.hasPreciseScrollingDeltas else { return false }
		// Momentum after a recognized swipe is swallowed; any other momentum is left alone.
		if event.momentumPhase != [] { return hasRecognizedSwipe }
		switch event.phase {
		case .began:
			swipeTravel = .zero
			hasRecognizedSwipe = false
			let point = convert(event.locationInWindow, from: nil)
			let option = event.modifierFlags.contains(.option)
			isTrackingSwipe =
				bounds.contains(point)
				&& (swipe == .optionSwipe ? option : !option && !scrollsSideways(at: point))
			return false
		case .changed:
			guard isTrackingSwipe, !hasRecognizedSwipe else { return hasRecognizedSwipe }
			swipeTravel.width += event.scrollingDeltaX
			swipeTravel.height += event.scrollingDeltaY
			guard RiftSidebarMath.swipeIsRecognized(travel: swipeTravel) else { return false }
			hasRecognizedSwipe = true
			let collapse = RiftSidebarMath.swipeCollapses(dx: swipeTravel.width, position: position)
			setCollapsed(collapse, animated: true, byUser: true)
			return true
		case .ended, .cancelled:
			isTrackingSwipe = false
			return hasRecognizedSwipe
		default:
			return false
		}
	}

	/// Whether something under `point` scrolls sideways (a swipe there is left to it).
	private func scrollsSideways(at point: CGPoint) -> Bool {
		var view = hitTest(convert(point, to: superview))
		while let current = view, current !== self {
			if let scroll = current as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor,
				let document = scroll.documentView,
				document.frame.width > scroll.contentView.bounds.width + 0.5
			{
				return true
			}
			view = current.superview
		}
		return false
	}
}

/// The strip along the sidebar's inner edge that resizes it.
final class RiftSidebarResizeHandle: NSView {
	var onDrag: ((CGFloat) -> Void)?
	var onDragEnd: (() -> Void)?

	override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	override func mouseDown(with event: NSEvent) {
		guard let window, let container = superview else { return }
		window.trackEvents(
			matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking
		) {
			[weak self] event, stop in
			guard let event else { return }
			MainActor.assumeIsolated {
				let x = container.convert(event.locationInWindow, from: nil).x
				if event.type == .leftMouseUp {
					self?.onDragEnd?()
					stop.pointee = true
				} else {
					self?.onDrag?(x)
				}
			}
		}
	}
}

/// The sidebar's toggle: a borderless 13pt symbol in the label colour, at 70% until the pointer
/// is over it, with a rounded hover background.
public final class RiftChromeIconButton: NSButton {
	public var symbolName = "sidebar.leading" {
		didSet { if symbolName != oldValue { updateImage() } }
	}
	/// The symbol's opacity while the pointer is elsewhere.
	public var restingForegroundOpacity: CGFloat = 0.7 { didSet { updateAppearance() } }
	public var foregroundColor: NSColor = .labelColor { didSet { updateAppearance() } }
	public var hoverBackgroundColor: NSColor = .quaternaryLabelColor { didSet { updateAppearance() } }
	/// Builds the menu shown on right-click (or Control-click); `nil` shows none.
	public var menuProvider: (() -> NSMenu?)?

	public override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

	private let hoverLayer = CALayer()
	private var trackingArea: NSTrackingArea?
	private var isHovered = false { didSet { if isHovered != oldValue { updateAppearance() } } }

	public override init(frame: NSRect) {
		super.init(frame: frame)
		isBordered = false
		bezelStyle = .regularSquare
		imagePosition = .imageOnly
		imageScaling = .scaleNone
		wantsLayer = true
		hoverLayer.cornerRadius = 6
		hoverLayer.cornerCurve = .continuous
		hoverLayer.zPosition = -1
		layer?.addSublayer(hoverLayer)
		updateImage()
	}

	@available(*, unavailable)
	public required init?(coder: NSCoder) { fatalError() }

	public override func layout() {
		super.layout()
		hoverLayer.frame = bounds
	}

	public override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea { removeTrackingArea(trackingArea) }
		let area = NSTrackingArea(
			rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
		addTrackingArea(area)
		trackingArea = area
	}

	public override func mouseEntered(with event: NSEvent) { isHovered = true }
	public override func mouseExited(with event: NSEvent) { isHovered = false }
	public override var mouseDownCanMoveWindow: Bool { false }
	public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	public override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		updateAppearance()
	}

	private func updateImage() {
		let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
		image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
			.withSymbolConfiguration(configuration)
		updateAppearance()
	}

	private func updateAppearance() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }
		contentTintColor = foregroundColor.withAlphaComponent(isHovered ? 1 : restingForegroundOpacity)
		var background: CGColor?
		effectiveAppearance.performAsCurrentDrawingAppearance {
			background = hoverBackgroundColor.cgColor
		}
		hoverLayer.backgroundColor = isHovered ? background : nil
	}
}

/// A menu item that runs a closure.
final class RiftClosureMenuItem: NSMenuItem {
	private let handler: () -> Void

	init(title: String, handler: @escaping () -> Void) {
		self.handler = handler
		super.init(title: title, action: #selector(run), keyEquivalent: "")
		target = self
	}

	@available(*, unavailable)
	required init(coder: NSCoder) { fatalError() }

	@objc private func run() { handler() }
}
