import AppKit
import RiftCore

/// One tab in a `RiftTabBarView`.
public struct RiftTab<ID: Hashable>: Equatable {
	public var id: ID
	public var title: String
	/// Whether the tab shows a close button and can be closed from its menu.
	public var isClosable: Bool
	/// What the tab is busy doing ("is still working"); closing a busy tab asks first.
	public var activity: String?
	/// An SF Symbol shown before the title.
	public var symbolName: String?

	public init(
		id: ID, title: String, symbolName: String? = nil, isClosable: Bool = true,
		activity: String? = nil
	) {
		self.id = id
		self.title = title
		self.symbolName = symbolName
		self.isClosable = isClosable
		self.activity = activity
	}
}

// MARK: - Looks

/// The tab bar's three surfaces: the track behind the tabs, the selected tab, and a hovered tab.
public struct RiftTabSurfaces: Hashable, Sendable {
	public struct Looks: Hashable, Sendable {
		public var track: RiftSurfaceStyle
		public var inactiveWindowTrack: RiftSurfaceStyle
		public var selection: RiftSurfaceStyle
		public var inactiveWindowSelection: RiftSurfaceStyle
		public var hover: RiftSurfaceStyle
		/// How far the track is drawn inside its frame.
		public var trackInset: CGFloat

		public init(
			track: RiftSurfaceStyle, inactiveWindowTrack: RiftSurfaceStyle,
			selection: RiftSurfaceStyle, inactiveWindowSelection: RiftSurfaceStyle,
			hover: RiftSurfaceStyle, trackInset: CGFloat = 0
		) {
			self.trackInset = trackInset
			self.track = track
			self.inactiveWindowTrack = inactiveWindowTrack
			self.selection = selection
			self.inactiveWindowSelection = inactiveWindowSelection
			self.hover = hover
		}
	}

	public var light: Looks
	public var dark: Looks

	public init(light: Looks, dark: Looks) {
		self.light = light
		self.dark = dark
	}

	/// The built-in look.
	///
	/// - Track: a 40pt-radius capsule, white at 5% (dark; 3% in background windows, 2% compact, and
	///   inset 1pt in compact), black at 5% (light; plus-darker in comfortable; none in background
	///   windows).
	/// - Selected tab: plain glass at 16.5pt corners. Dark background windows add a 1pt white
	///   outline at 5%. Light adds a 25% tint (the canvas; white in compact) and, in the key window,
	///   a soft shadow (black at 40%, opacity 0.15, 3.5pt blur, 1.5pt down).
	/// - Hovered tab: white at 13% (10% compact) with a 5% white overlay on top (dark),
	///   plus-darker black at 5% (light).
	public static func modern(_ density: RiftChromeDensity) -> RiftTabSurfaces {
		func rgb(_ v: CGFloat, _ a: CGFloat) -> NSColor {
			NSColor(srgbRed: v, green: v, blue: v, alpha: a)
		}
		let canvas: CGFloat = 0.117647
		let compact = density == .compact

		var darkTrack = RiftSurfaceStyle()
		darkTrack.cornerRadius = RiftTabBarMath.trackCornerRadius
		darkTrack.fill = RiftSurfaceFill(color: rgb(1, 0.05))
		var darkInactiveTrack = darkTrack
		darkInactiveTrack.fill = RiftSurfaceFill(color: rgb(1, compact ? 0.02 : 0.03))
		var darkSelection = RiftSurfaceStyle()
		darkSelection.cornerRadius = RiftTabBarMath.tabCornerRadius
		darkSelection.glass = RiftSurfaceGlass()
		var darkInactiveSelection = darkSelection
		darkInactiveSelection.strokes = [RiftSurfaceStroke(color: rgb(1, 0.05))]
		var darkHover = RiftSurfaceStyle()
		darkHover.cornerRadius = RiftTabBarMath.tabCornerRadius
		darkHover.backdrop = RiftSurfaceFill(color: rgb(1, compact ? 0.1 : 0.13))
		darkHover.fill = RiftSurfaceFill(color: rgb(1, 0.05), blendMode: .overlay)

		var lightTrack = RiftSurfaceStyle()
		lightTrack.cornerRadius = RiftTabBarMath.trackCornerRadius
		lightTrack.fill = RiftSurfaceFill(color: rgb(0, 0.05), blendMode: compact ? .normal : .plusDarker)
		var lightInactiveTrack = RiftSurfaceStyle()
		lightInactiveTrack.cornerRadius = RiftTabBarMath.trackCornerRadius
		var lightInactiveSelection = RiftSurfaceStyle()
		lightInactiveSelection.cornerRadius = RiftTabBarMath.tabCornerRadius
		lightInactiveSelection.glass = RiftSurfaceGlass(tint: compact ? rgb(1, 0.25) : rgb(canvas, 0.25))
		var lightSelection = lightInactiveSelection
		lightSelection.shadows = [
			RiftSurfaceShadow(
				color: rgb(0, 0.4), opacity: 0.15, radius: 3.5, offset: CGSize(width: 0, height: 1.5))
		]
		var lightHover = RiftSurfaceStyle()
		lightHover.cornerRadius = RiftTabBarMath.tabCornerRadius
		lightHover.fill = RiftSurfaceFill(color: rgb(0, 0.05), blendMode: .plusDarker)

		return RiftTabSurfaces(
			light: Looks(
				track: lightTrack, inactiveWindowTrack: lightInactiveTrack, selection: lightSelection,
				inactiveWindowSelection: lightInactiveSelection, hover: lightHover),
			dark: Looks(
				track: darkTrack, inactiveWindowTrack: darkInactiveTrack, selection: darkSelection,
				inactiveWindowSelection: darkInactiveSelection, hover: darkHover,
				trackInset: compact ? 1 : 0))
	}

	/// These looks with their canvas-grey tints taken from the theme's canvas colour.
	public func themed(_ selection: RiftThemeSelection) -> RiftTabSurfaces {
		func looks(_ l: Looks, _ theme: RiftTheme) -> Looks {
			Looks(
				track: l.track.rift_themed(theme),
				inactiveWindowTrack: l.inactiveWindowTrack.rift_themed(theme),
				selection: l.selection.rift_themed(theme),
				inactiveWindowSelection: l.inactiveWindowSelection.rift_themed(theme),
				hover: l.hover.rift_themed(theme), trackInset: l.trackInset)
		}
		return RiftTabSurfaces(
			light: looks(light, selection.light), dark: looks(dark, selection.dark))
	}

	func looks(isDark: Bool) -> Looks { isDark ? dark : light }
}

// MARK: - Pane drops

/// A view a dragged pane can be dropped on outside a layout (a tab bar).
@MainActor
protocol RiftPaneDropAccepting: NSView {
	var paneDropGroup: String? { get }
	/// The pointer (in this view's coordinates) moved during a pane drag; returns whether a drop
	/// here would be taken.
	func paneDragMoved(to point: CGPoint, pane: AnyHashable) -> Bool
	/// The pane drag left this view or ended.
	func paneDragExited()
	/// Takes the dropped pane; returns whether it did (the pane is then removed from its layout).
	func acceptPaneDrop(_ pane: AnyHashable) -> Bool
}

// MARK: - Tab bar

/// A row of tabs: they share the width (up to 240pt each, at least 64, scrolling beyond that),
/// slide when reordered, and can be dragged, closed, renamed and opened from a pane drag.
///
/// - Click a tab to select it; click the selected tab again to rename it.
/// - Drag a tab to move it; dropped outside the window, it is torn off (`onTearOff`).
/// - Hover a dragged pane over a tab for 0.32s to open it; drop the pane between tabs to make
///   it a new tab there (`onPaneDrop`).
/// - Closing a tab keeps the others' widths while the pointer stays over the bar.
@MainActor
public final class RiftTabBarView<ID: Hashable>: NSView, RiftPaneDropAccepting {
	// MARK: Content

	public var tabs: [RiftTab<ID>] = [] { didSet { if tabs != oldValue { tabsChanged(from: oldValue) } } }
	public var selectedTab: ID? {
		didSet {
			if selectedTab != oldValue {
				revealsSelectedTab = true
				animatesNextLayout = window != nil
				needsLayout = true
				updateChrome()
			}
		}
	}

	// MARK: Options

	public var density: RiftChromeDensity = .comfortable {
		didSet { if density != oldValue { restyle(); invalidateIntrinsicContentSize() } }
	}
	/// Tabs share all the width instead of stopping at 240pt.
	public var fillsAvailableSpace = false {
		didSet { if fillsAvailableSpace != oldValue { needsLayout = true } }
	}
	public var showsNewTabButton = true {
		didSet { if showsNewTabButton != oldValue { needsLayout = true } }
	}
	/// Room at the leading edge (for the window buttons).
	public var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { needsLayout = true } } }
	public var trailingInset: CGFloat = 0 { didSet { if trailingInset != oldValue { needsLayout = true } } }
	public var surfaces: RiftTabSurfaces = .modern(.comfortable) {
		didSet { if surfaces != oldValue { restyle() } }
	}
	/// Takes the surfaces' tints and the text colours from a theme.
	public var theme: RiftThemeSelection? { didSet { if theme != oldValue { restyle() } } }
	/// Views that can trade panes with this bar (see `RiftConfiguration.dragGroup`).
	public var paneDropGroup: String?

	// MARK: Callbacks

	public var onSelect: ((ID) -> Void)?
	/// Close a tab (after any confirmation).
	public var onClose: ((ID) -> Void)?
	/// Close every tab but this one (after any confirmation).
	public var onCloseOthers: ((ID) -> Void)?
	/// A tab moved to an index.
	public var onMove: ((ID, Int) -> Void)?
	public var onNewTab: (() -> Void)?
	public var onRename: ((ID, String) -> Void)?
	/// A tab dropped outside every window, at a screen point.
	public var onTearOff: ((ID, CGPoint) -> Void)?
	/// A dragged pane dropped between tabs: make it a new tab at the index. Return whether it was
	/// taken (it is then removed from its layout).
	public var onPaneDrop: ((AnyHashable, Int) -> Bool)?

	// MARK: State

	private let trackSurface = RiftSurfaceStackView()
	private let clipView = RiftTabClipView()
	private let selectionSurface = RiftSurfaceStackView()
	private let placeholder = RiftSurfaceStackView()
	private let newTabButton = RiftChromeIconButton()
	private var itemViews: [ID: RiftTabItemView<ID>] = [:]
	private var scrollOffset: CGFloat = 0
	private var revealsSelectedTab = true
	private var animatesNextLayout = false
	private var resolved: RiftTabBarLayout?
	/// Tab width kept after a close while the pointer stays over the bar.
	private var heldTabWidth: CGFloat?
	private var hoveredTab: ID? { didSet { if hoveredTab != oldValue { updateChrome() } } }
	private var trackingArea: NSTrackingArea?
	private let confirmation = RiftCloseConfirmation()
	private var trackInset: CGFloat = 0
	/// Room a sidebar asks for (its window buttons and toggle), on top of the insets.
	private var chromeRoom: (leading: CGFloat, trailing: CGFloat) = (0, 0)

	// Tab drag
	private var draggedTab: ID?
	private var dragOrder: [ID]?
	private var dragOriginalOrder: [ID] = []
	private var dragStartPointer: CGPoint = .zero
	private var dragStartOrigin: CGPoint = .zero

	// Pane drag
	private var paneDropIndex: Int?
	private var springLoadedTab: ID?
	private var springLoadTimer: Timer?

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		addSubview(trackSurface)
		clipView.wantsLayer = true
		clipView.layer?.masksToBounds = true
		addSubview(clipView)
		clipView.addSubview(placeholder)
		placeholder.isHidden = true
		clipView.addSubview(selectionSurface)
		newTabButton.symbolName = "plus"
		newTabButton.target = self
		newTabButton.action = #selector(newTab)
		newTabButton.toolTip = "New Tab"
		addSubview(newTabButton)
		restyle()
		RiftViewRegistry.register(self)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	public override var isFlipped: Bool { true }
	public override var mouseDownCanMoveWindow: Bool { false }

	public override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: RiftTabBarMath.buttonSize(density: density) + 4)
	}

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		let center = NotificationCenter.default
		center.removeObserver(self)
		if let window {
			for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
				center.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: window)
			}
		}
		restyle()
	}

	@objc private func windowKeyChanged() { restyle() }

	public override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		restyle()
	}

	// MARK: Layout

	public override func layout() {
		super.layout()
		let order = dragOrder ?? tabs.map(\.id)
		let slotCount = order.count + (paneDropIndex == nil ? 0 : 1)
		let leading = leadingInset + chromeRoom.leading
		let trailing = trailingInset + chromeRoom.trailing
		var layout = RiftTabBarLayout.resolve(
			bounds: bounds, count: slotCount, density: density, leadingInset: leading,
			trailingInset: trailing, showsNewTabButton: showsNewTabButton,
			fills: fillsAvailableSpace, scrollOffset: scrollOffset, heldTabWidth: heldTabWidth)
		if revealsSelectedTab, let selectedTab, let index = order.firstIndex(of: selectedTab),
			layout.tabFrames.indices.contains(index)
		{
			revealsSelectedTab = false
			let frame = layout.tabFrames[index]
			let base = layout.trackFrame.minX - layout.scrollOffset
			let offset = RiftTabBarMath.revealingOffset(
				current: layout.scrollOffset, tabMinX: frame.minX - base, tabMaxX: frame.maxX - base,
				trackWidth: layout.trackFrame.width, maximum: layout.maximumScrollOffset)
			if offset != layout.scrollOffset {
				scrollOffset = offset
				layout = RiftTabBarLayout.resolve(
					bounds: bounds, count: slotCount, density: density, leadingInset: leading,
					trailingInset: trailing, showsNewTabButton: showsNewTabButton,
					fills: fillsAvailableSpace, scrollOffset: offset, heldTabWidth: heldTabWidth)
			}
		}
		scrollOffset = layout.scrollOffset
		resolved = layout

		let animated = animatesNextLayout
		animatesNextLayout = false
		let track = layout.trackFrame
		place(trackSurface, track.insetBy(dx: trackInset - 2, dy: trackInset - 2), animated: animated)
		place(clipView, track.insetBy(dx: -2, dy: -4), animated: false)
		let toClip = CGPoint(x: -(track.minX - 2), y: -(track.minY - 4))

		newTabButton.isHidden = layout.newTabButtonFrame == nil
		if let frame = layout.newTabButtonFrame { place(newTabButton, frame, animated: animated) }

		// Tabs fill the slots in order, skipping the pane-drop placeholder's slot.
		var slots = layout.tabFrames.map { $0.offsetBy(dx: toClip.x, dy: toClip.y) }
		if let index = paneDropIndex, slots.indices.contains(index) {
			let frame = slots.remove(at: index)
			if placeholder.isHidden {
				placeholder.frame = frame.insetBy(dx: frame.width / 2, dy: 0)
				placeholder.isHidden = false
			}
			place(placeholder, frame, animated: true)
		} else {
			placeholder.isHidden = true
		}
		for (index, id) in order.enumerated() {
			guard let view = itemViews[id], slots.indices.contains(index) else { continue }
			if id == draggedTab {
				// The dragged tab follows the pointer; only its size follows the layout.
				view.setFrameSize(slots[index].size)
				continue
			}
			let isNew = view.frame.isEmpty
			if isNew { view.frame = slots[index] }
			place(view, slots[index], animated: animated && !isNew)
		}
		if let selectedTab, let view = itemViews[selectedTab],
			let index = order.firstIndex(of: selectedTab), slots.indices.contains(index)
		{
			selectionSurface.isHidden = false
			let target = selectedTab == draggedTab ? view.frame : slots[index]
			if selectionSurface.frame.isEmpty { selectionSurface.frame = target }
			place(selectionSurface, target, animated: animated && selectedTab != draggedTab)
		} else {
			selectionSurface.isHidden = true
		}
		updateChrome()
	}

	private func place(_ view: NSView, _ frame: CGRect, animated: Bool) {
		guard view.frame != frame else { return }
		if animated {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = RiftTabBarMath.geometryDuration
				context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
				context.allowsImplicitAnimation = true
				view.animator().frame = frame
			}
		} else {
			view.frame = frame
		}
	}

	private func layoutAnimated() {
		animatesNextLayout = true
		needsLayout = true
		layoutSubtreeIfNeeded()
	}

	// MARK: Tabs

	private func tabsChanged(from old: [RiftTab<ID>]) {
		let ids = Set(tabs.map(\.id))
		for (id, view) in itemViews where !ids.contains(id) {
			view.removeFromSuperview()
			itemViews[id] = nil
		}
		for tab in tabs {
			let view = itemViews[tab.id] ?? makeItemView(tab.id)
			view.title = tab.title
			view.symbolName = tab.symbolName
			view.isClosable = tab.isClosable
		}
		if let draggedTab, !ids.contains(draggedTab) { endTabDrag(cancelled: true) }
		if dragOrder != nil { dragOrder = dragOrder?.filter(ids.contains) }
		if old.map(\.id) != tabs.map(\.id) { animatesNextLayout = window != nil && !old.isEmpty }
		needsLayout = true
		updateChrome()
	}

	private func makeItemView(_ id: ID) -> RiftTabItemView<ID> {
		let view = RiftTabItemView<ID>(id: id)
		view.bar = self
		clipView.addSubview(view, positioned: .above, relativeTo: selectionSurface)
		itemViews[id] = view
		let looks = (theme.map { surfaces.themed($0) } ?? surfaces).looks(isDark: isDark)
		view.applyLooks(
			hover: looks.hover, density: density, textColor: textColor, windowActive: isWindowActive)
		return view
	}

	private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
	private var isWindowActive: Bool { window?.isKeyWindow ?? true }

	private var textColor: NSColor {
		guard let theme else { return .labelColor }
		return .rift(.content, in: theme)
	}

	private func restyle() {
		let base = theme.map { surfaces.themed($0) } ?? surfaces
		let looks = base.looks(isDark: isDark)
		trackSurface.style = isWindowActive ? looks.track : looks.inactiveWindowTrack
		selectionSurface.style = isWindowActive ? looks.selection : looks.inactiveWindowSelection
		var placeholderStyle = RiftSurfaceStyle()
		placeholderStyle.cornerRadius = RiftTabBarMath.tabCornerRadius
		placeholderStyle.fill = RiftSurfaceFill(color: .controlAccentColor.withAlphaComponent(0.16))
		placeholderStyle.strokes = [
			RiftSurfaceStroke(color: .controlAccentColor.withAlphaComponent(0.5))
		]
		placeholder.style = placeholderStyle
		newTabButton.foregroundColor = textColor
		for view in itemViews.values {
			view.applyLooks(
				hover: looks.hover, density: density, textColor: textColor,
				windowActive: isWindowActive)
		}
		trackInset = looks.trackInset
		needsLayout = true
	}

	/// Dividers, hover and z-order: the dragged tab on top, then the selected, then the hovered.
	private func updateChrome() {
		let order = dragOrder ?? tabs.map(\.id)
		var highlighted = Set<Int>()
		for (index, id) in order.enumerated()
		where id == selectedTab || id == hoveredTab || id == draggedTab {
			highlighted.insert(index)
		}
		for (index, id) in order.enumerated() {
			guard let view = itemViews[id] else { continue }
			view.showsDivider =
				paneDropIndex == nil && RiftTabBarMath.showsDivider(atTab: index, highlighted: highlighted)
			view.isHovered = id == hoveredTab && draggedTab == nil
			view.isSelected = id == selectedTab
			view.layer?.zPosition =
				id == draggedTab ? 4 : id == selectedTab ? 3 : id == hoveredTab ? 2 : 1
		}
		selectionSurface.layer?.zPosition = selectedTab == draggedTab && draggedTab != nil ? 3.5 : 0
	}

	// MARK: Pointer

	public override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea { removeTrackingArea(trackingArea) }
		let area = NSTrackingArea(
			rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
			owner: self)
		addTrackingArea(area)
		trackingArea = area
	}

	public override func mouseMoved(with event: NSEvent) { updateHover(event) }
	public override func mouseEntered(with event: NSEvent) { updateHover(event) }

	public override func mouseExited(with event: NSEvent) {
		hoveredTab = nil
		if heldTabWidth != nil {
			heldTabWidth = nil
			layoutAnimated()
		}
	}

	private func refreshHoverFromPointer() {
		guard let window, draggedTab == nil else { return }
		let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
		hoveredTab = bounds.contains(point) ? tab(at: point) : nil
	}

	private func updateHover(_ event: NSEvent) {
		guard draggedTab == nil else { return }
		hoveredTab = tab(at: convert(event.locationInWindow, from: nil))
	}

	private func tab(at point: CGPoint) -> ID? {
		let inClip = clipView.convert(point, from: self)
		guard clipView.bounds.contains(inClip) else { return nil }
		return itemViews.first { $0.value.frame.contains(inClip) }?.key
	}

	public override func scrollWheel(with event: NSEvent) {
		guard let resolved, resolved.maximumScrollOffset > 0 else { return super.scrollWheel(with: event) }
		let delta =
			abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
			? event.scrollingDeltaX : event.scrollingDeltaY
		let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
		scrollOffset = min(max(scrollOffset - delta * scale, 0), resolved.maximumScrollOffset)
		needsLayout = true
	}

	public override func mouseDown(with event: NSEvent) {
		// A double-click on the empty bar opens a new tab.
		if event.clickCount == 2, tab(at: convert(event.locationInWindow, from: nil)) == nil {
			onNewTab?()
		}
	}

	@objc private func newTab() { onNewTab?() }

	// MARK: Tab item callbacks

	func itemClicked(_ id: ID) {
		if selectedTab != id { onSelect?(id) }
	}

	func itemRequestsRename(_ id: ID) {
		itemViews[id]?.beginRenaming()
	}

	func itemRenamed(_ id: ID, to title: String) {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != tabs.first(where: { $0.id == id })?.title else { return }
		onRename?(id, trimmed)
	}

	func itemClose(_ id: ID) {
		guard let tab = tabs.first(where: { $0.id == id }), tab.isClosable else { return }
		let close = { [weak self] in
			guard let self else { return }
			// Keep tab widths until the pointer leaves, so the next close button lands under it.
			if let resolved = self.resolved, self.tabs.count > 1 { self.heldTabWidth = resolved.tabWidth }
			self.onClose?(id)
			// The tab that slides under the pointer is hovered (and shows its close button)
			// without the pointer moving.
			DispatchQueue.main.asyncAfter(deadline: .now() + RiftTabBarMath.geometryDuration) {
				[weak self] in self?.refreshHoverFromPointer()
			}
		}
		guard let activity = tab.activity else { return close() }
		presentConfirmation(.tab, busy: [(tab, activity)], spotlight: id, confirm: close)
	}

	func itemCloseOthers(_ id: ID) {
		let busy = tabs.compactMap { tab in
			tab.id != id && tab.isClosable ? tab.activity.map { (tab, $0) } : nil
		}
		let close = { [weak self] in self?.onCloseOthers?(id) ?? () }
		guard !busy.isEmpty else { return close() }
		presentConfirmation(.otherTabs, busy: busy, spotlight: busy[0].0.id, confirm: close)
	}

	private func presentConfirmation(
		_ subject: RiftCloseSubject, busy: [(RiftTab<ID>, String)], spotlight: ID,
		confirm: @escaping () -> Void
	) {
		let host = window?.contentView ?? self
		let rows = busy.enumerated().map { index, entry in
			RiftCloseConfirmation.Row(id: index, text: "\(entry.0.title) \(entry.1)") { [weak self] in
				self?.onSelect?(entry.0.id)
			}
		}
		let rect = itemViews[spotlight].map { host.convert($0.bounds, from: $0) } ?? .zero
		confirmation.present(
			subject: subject, rows: rows, in: host, spotlight: rect, confirm: confirm, cancel: {})
	}

	func menu(for id: ID) -> NSMenu {
		let menu = NSMenu()
		let order = tabs.map(\.id)
		let index = order.firstIndex(of: id) ?? 0
		menu.addItem(RiftClosureMenuItem(title: "Rename Tab…") { [weak self] in self?.itemRequestsRename(id) })
		menu.addItem(.separator())
		let back = RiftClosureMenuItem(title: "Move Tab Backward") { [weak self] in
			self?.onMove?(id, index - 1)
		}
		back.isEnabled = index > 0
		menu.addItem(back)
		let forward = RiftClosureMenuItem(title: "Move Tab Forward") { [weak self] in
			self?.onMove?(id, index + 1)
		}
		forward.isEnabled = index + 1 < order.count
		menu.addItem(forward)
		menu.addItem(.separator())
		let close = RiftClosureMenuItem(title: "Close Tab") { [weak self] in self?.itemClose(id) }
		close.isEnabled = tabs.first { $0.id == id }?.isClosable ?? false
		menu.addItem(close)
		let others = RiftClosureMenuItem(title: "Close Other Tabs") { [weak self] in
			self?.itemCloseOthers(id)
		}
		others.isEnabled = tabs.contains { $0.id != id && $0.isClosable }
		menu.addItem(others)
		menu.autoenablesItems = false
		return menu
	}

	// MARK: Tab drag

	func beginTabDrag(_ id: ID, pointer: CGPoint) {
		guard let view = itemViews[id] else { return }
		hoveredTab = nil
		draggedTab = id
		dragOriginalOrder = tabs.map(\.id)
		dragOrder = dragOriginalOrder
		dragStartPointer = clipView.convert(pointer, from: nil)
		dragStartOrigin = view.frame.origin
		clipView.layer?.masksToBounds = false
		if selectedTab != id { onSelect?(id) }
		updateChrome()
	}

	func moveTabDrag(_ id: ID, pointer: CGPoint) {
		guard draggedTab == id, var order = dragOrder, let view = itemViews[id],
			let resolved
		else { return }
		let track = resolved.trackFrame.offsetBy(
			dx: -(resolved.trackFrame.minX - 2), dy: -(resolved.trackFrame.minY - 4))
		let origin = RiftTabBarMath.draggedOrigin(
			pointer: clipView.convert(pointer, from: nil), startPointer: dragStartPointer,
			startOrigin: dragStartOrigin, size: view.frame.size,
			track: CGRect(
				x: track.minX - scrollOffset, y: track.minY, width: max(track.width, contentWidth(resolved)),
				height: track.height))
		view.setFrameOrigin(origin)
		if selectedTab == id { selectionSurface.frame = view.frame }

		guard let current = order.firstIndex(of: id) else { return }
		let mids = resolved.tabFrames.map { $0.midX - (resolved.trackFrame.minX - 2) }
		let target = RiftTabBarMath.reorderedIndex(
			draggedMidX: view.frame.midX, current: current, slotMidXs: mids)
		if target != current {
			order.remove(at: current)
			order.insert(id, at: target)
			dragOrder = order
			layoutAnimated()
		}
	}

	private func contentWidth(_ layout: RiftTabBarLayout) -> CGFloat {
		RiftTabBarMath.contentWidth(tabWidth: layout.tabWidth, count: layout.tabFrames.count)
	}

	func endTabDrag(_ id: ID? = nil, screenPoint: CGPoint? = nil, cancelled: Bool = false) {
		guard let dragged = draggedTab else { return }
		let order = dragOrder ?? dragOriginalOrder
		// Torn off when no window of this app is under the pointer.
		let outsideWindows = screenPoint.map { point in
			NSApp.window(
				withWindowNumber: NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0))
				== nil
		}
		draggedTab = nil
		dragOrder = nil
		clipView.layer?.masksToBounds = true
		if !cancelled, let screenPoint, outsideWindows == true, let onTearOff, tabs.count > 1 {
			layoutAnimated()
			onTearOff(dragged, screenPoint)
			return
		}
		if !cancelled, let index = order.firstIndex(of: dragged),
			index != dragOriginalOrder.firstIndex(of: dragged)
		{
			onMove?(dragged, index)
		}
		// The tab returns to its slot.
		layoutAnimated()
	}

	// MARK: Pane drops

	func paneDragMoved(to point: CGPoint, pane: AnyHashable) -> Bool {
		guard onPaneDrop != nil, bounds.contains(point), let resolved else {
			paneDragExited()
			return false
		}
		let inClip = clipView.convert(point, from: self)
		// The placeholder slot follows the pointer, with the same give as dragging a tab.
		let base = resolved.trackFrame.minX - 2
		let mids = resolved.tabFrames.map { $0.midX - base }
		let index: Int
		if let current = paneDropIndex {
			index = RiftTabBarMath.reorderedIndex(draggedMidX: inClip.x, current: current, slotMidXs: mids)
		} else {
			index = tabs.filter { itemViews[$0.id].map { $0.frame.midX < inClip.x } ?? false }.count
		}
		if index != paneDropIndex {
			paneDropIndex = index
			layoutAnimated()
		}
		// Spring-loading: hovering a tab opens it.
		let hovered = itemViews.first { $0.value.frame.contains(inClip) }?.key
		if hovered != springLoadedTab {
			springLoadTimer?.invalidate()
			springLoadedTab = hovered
			if let hovered, hovered != selectedTab {
				springLoadTimer = Timer.scheduledTimer(
					withTimeInterval: RiftTabBarMath.springLoadDelay, repeats: false
				) { [weak self] _ in
					MainActor.assumeIsolated { self?.springLoad() }
				}
			}
		}
		return true
	}

	private func springLoad() {
		guard let id = springLoadedTab else { return }
		itemViews[id]?.pulse()
		onSelect?(id)
	}

	func paneDragExited() {
		springLoadTimer?.invalidate()
		springLoadTimer = nil
		springLoadedTab = nil
		guard paneDropIndex != nil else { return }
		paneDropIndex = nil
		layoutAnimated()
	}

	func acceptPaneDrop(_ pane: AnyHashable) -> Bool {
		let index = min(paneDropIndex ?? tabs.count, tabs.count)
		paneDragExited()
		return onPaneDrop?(pane, index) ?? false
	}

	isolated deinit {
		springLoadTimer?.invalidate()
		NotificationCenter.default.removeObserver(self)
	}
}

extension RiftTabBarView: RiftSidebarChromeObserving {
	public func riftSidebarChromeDidChange(_ chrome: RiftSidebarChrome) {
		let room = (chrome.leadingButtonRoom, chrome.trailingButtonRoom)
		guard room != chromeRoom else { return }
		chromeRoom = room
		needsLayout = true
	}
}

/// The strip tabs scroll in.
final class RiftTabClipView: NSView {
	override var isFlipped: Bool { true }
	override func hitTest(_ point: NSPoint) -> NSView? {
		let hit = super.hitTest(point)
		return hit === self ? nil : hit
	}
}

// MARK: - Tab item

@MainActor
final class RiftTabItemView<ID: Hashable>: NSView, NSTextFieldDelegate {
	let id: ID
	weak var bar: RiftTabBarView<ID>?

	var title = "" {
		didSet {
			guard title != oldValue else { return }
			label.stringValue = title
			toolTip = title
			setAccessibilityLabel(title)
		}
	}
	var symbolName: String? {
		didSet {
			guard symbolName != oldValue else { return }
			icon.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
				.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
			icon.isHidden = icon.image == nil
			needsLayout = true
		}
	}
	var isClosable = true { didSet { updateVisibility() } }
	/// Keeps the close button showing (the tab slid under the pointer after a close).
	var keepsCloseButtonShown = false { didSet { if keepsCloseButtonShown != oldValue { updateVisibility() } } }
	var isHovered = false { didSet { if isHovered != oldValue { updateVisibility(animated: true) } } }
	var isSelected = false {
		didSet {
			if isSelected != oldValue {
				updateVisibility()
				setAccessibilityValue(isSelected ? "selected" : nil)
			}
		}
	}
	var showsDivider = true {
		didSet {
			guard showsDivider != oldValue else { return }
			CATransaction.begin()
			CATransaction.setAnimationDuration(0.14)
			divider.opacity = showsDivider ? 1 : 0
			CATransaction.commit()
		}
	}

	private let hoverSurface = RiftSurfaceStackView()
	private let divider = CALayer()
	private let label = NSTextField(labelWithString: "")
	private let icon = NSImageView()
	private let fadeMask = CAGradientLayer()
	private let closeButton = RiftChromeIconButton()
	private var editor: NSTextField?
	private var density: RiftChromeDensity = .comfortable

	// Press tracking
	private var pressPoint: CGPoint?
	private var isDragging = false
	private var armsRename = false

	init(id: ID) {
		self.id = id
		super.init(frame: .zero)
		wantsLayer = true
		layer?.masksToBounds = false
		hoverSurface.alphaValue = 0
		addSubview(hoverSurface)
		divider.opacity = 1
		layer?.addSublayer(divider)
		label.lineBreakMode = .byClipping
		// Every tab's title: 13pt regular in the bar's foreground colour.
		label.font = .systemFont(ofSize: 13, weight: .regular)
		label.wantsLayer = true
		fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
		fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
		fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
		label.layer?.mask = fadeMask
		addSubview(label)
		icon.isHidden = true
		icon.imageScaling = .scaleProportionallyDown
		addSubview(icon)
		closeButton.symbolName = "xmark"
		closeButton.symbolPointSize = 10
		closeButton.restingForegroundOpacity = 0.7
		closeButton.target = self
		closeButton.action = #selector(closeClicked)
		closeButton.toolTip = "Close Tab"
		addSubview(closeButton)
		setAccessibilityElement(true)
		setAccessibilityRole(.radioButton)
		updateVisibility()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override var isFlipped: Bool { true }
	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	func applyLooks(
		hover: RiftSurfaceStyle, density: RiftChromeDensity, textColor: NSColor, windowActive: Bool
	) {
		self.density = density
		hoverSurface.style = hover
		label.textColor = textColor
		icon.contentTintColor = textColor
		closeButton.foregroundColor = textColor
		// The separator colour at 18% (13.5% in background windows).
		effectiveAppearance.performAsCurrentDrawingAppearance {
			divider.backgroundColor =
				NSColor.separatorColor.withAlphaComponent(windowActive ? 0.18 : 0.135).cgColor
		}
		needsLayout = true
	}

	override func layout() {
		super.layout()
		let item = RiftTabItemLayout.resolve(
			size: bounds.size, density: density, showsCloseButton: showsCloseButton,
			hasIcon: !icon.isHidden)
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		hoverSurface.frame = item.hoverFrame
		var style = hoverSurface.style
		style.cornerRadius = item.cornerRadius
		hoverSurface.style = style
		divider.frame = item.dividerFrame
		closeButton.frame = item.closeButtonFrame
		if let frame = item.iconFrame { icon.frame = frame }
		label.frame = item.titleFrame
		editor?.frame = item.titleFrame.insetBy(dx: -3, dy: -2)
		fadeMask.frame = label.bounds
		// Fade the last 16pt of a title that doesn't fit.
		let fits = label.attributedStringValue.size().width <= label.bounds.width
		let start = label.bounds.width > 0 ? max(0, 1 - 16 / label.bounds.width) : 1
		fadeMask.locations = fits ? [0, 1, 1] : [0, NSNumber(value: start), 1]
		CATransaction.commit()
	}

	/// Only while hovered (or kept showing by the bar).
	private var showsCloseButton: Bool { isClosable && (isHovered || keepsCloseButtonShown) }

	private func updateVisibility(animated: Bool = false) {
		closeButton.isHidden = !showsCloseButton
		let alpha: CGFloat = isHovered && !isSelected ? 1 : 0
		if animated {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.14
				hoverSurface.animator().alphaValue = alpha
			}
		} else {
			hoverSurface.alphaValue = alpha
		}
		needsLayout = true
	}

	/// The spring-loading flash: the tab swells a little and settles.
	func pulse() {
		guard let layer else { return }
		let pulse = CASpringAnimation(keyPath: "transform.scale")
		pulse.fromValue = 1.06
		pulse.toValue = 1
		pulse.damping = 12
		pulse.stiffness = 300
		pulse.mass = 1
		pulse.duration = pulse.settlingDuration
		layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
		layer.position = CGPoint(x: frame.midX, y: frame.midY)
		layer.add(pulse, forKey: "rift.springLoad")
	}

	@objc private func closeClicked() { bar?.itemClose(id) }

	override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: id) }

	// MARK: Press, drag, rename

	override func mouseDown(with event: NSEvent) {
		guard editor == nil else { return super.mouseDown(with: event) }
		pressPoint = event.locationInWindow
		isDragging = false
		// A click on the already-selected tab in the key window renames it.
		armsRename =
			isSelected && event.clickCount == 1 && (window?.isKeyWindow ?? false)
			&& NSApp.isActive
		if !isSelected { bar?.itemClicked(id) }
	}

	override func mouseDragged(with event: NSEvent) {
		guard let pressPoint, let bar else { return }
		let point = event.locationInWindow
		if !isDragging {
			guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) > RiftTabBarMath.dragThreshold
			else { return }
			isDragging = true
			armsRename = false
			bar.beginTabDrag(id, pointer: pressPoint)
		}
		bar.moveTabDrag(id, pointer: point)
	}

	override func mouseUp(with event: NSEvent) {
		defer { pressPoint = nil }
		if isDragging {
			isDragging = false
			let screen = window?.convertPoint(toScreen: event.locationInWindow)
			bar?.endTabDrag(id, screenPoint: screen)
			return
		}
		if armsRename, event.clickCount == 1 {
			armsRename = false
			beginRenaming()
		}
	}

	func beginRenaming() {
		guard editor == nil else { return }
		let field = NSTextField(string: title)
		field.font = label.font
		field.isBordered = false
		field.focusRingType = .none
		field.drawsBackground = true
		field.backgroundColor = .textBackgroundColor.withAlphaComponent(0.6)
		field.wantsLayer = true
		field.layer?.cornerRadius = 4
		field.delegate = self
		field.cell?.isScrollable = true
		addSubview(field)
		editor = field
		label.isHidden = true
		needsLayout = true
		layoutSubtreeIfNeeded()
		window?.makeFirstResponder(field)
		field.currentEditor()?.selectAll(nil)
	}

	func controlTextDidEndEditing(_ notification: Notification) {
		guard let field = editor else { return }
		let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
		let cancelled = movement == NSTextMovement.cancel.rawValue
		editor = nil
		field.removeFromSuperview()
		label.isHidden = false
		if !cancelled { bar?.itemRenamed(id, to: field.stringValue) }
	}

	func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
		if selector == #selector(cancelOperation(_:)) {
			editor?.stringValue = title
			window?.makeFirstResponder(bar)
			return true
		}
		return false
	}
}
