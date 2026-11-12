import AppKit
import RiftCore

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

	public var tabs: [RiftTab<ID>] = [] {
		didSet { if tabs != oldValue { tabsChanged(from: oldValue) } }
	}
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
		didSet {
			if density != oldValue {
				restyle()
				invalidateIntrinsicContentSize()
			}
		}
	}
	/// Tabs share all the width instead of stopping at 240pt.
	public var fillsAvailableSpace = false {
		didSet { if fillsAvailableSpace != oldValue { needsLayout = true } }
	}
	public var showsNewTabButton = true {
		didSet { if showsNewTabButton != oldValue { needsLayout = true } }
	}
	/// Room at the leading edge (for the window buttons).
	public var leadingInset: CGFloat = 0 {
		didSet { if leadingInset != oldValue { needsLayout = true } }
	}
	public var trailingInset: CGFloat = 0 {
		didSet { if trailingInset != oldValue { needsLayout = true } }
	}
	public var surfaces: RiftTabSurfaces = .modern(.comfortable) {
		didSet { if surfaces != oldValue { restyle() } }
	}
	/// Takes the surfaces' tints and the text colours from a theme.
	public var theme: RiftThemeSelection? { didSet { if theme != oldValue { restyle() } } }
	/// How tabs move, fade and settle.
	public var animation: RiftTabAnimation = .standard
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
	/// The tab returning to its slot after a drop (for one layout).
	private var returningTab: ID?
	private var dragOrder: [ID]?
	private var dragOriginalOrder: [ID] = []
	private var dragStartPointer: CGPoint = .zero
	private var dragStartOrigin: CGPoint = .zero

	// Pane drag
	private var paneDropIndex: Int?
	private var springLoadedTab: ID?
	private var springLoadTimer: Timer?
	private var springLoadRevision = 0

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
		NSSize(
			width: NSView.noIntrinsicMetric, height: RiftTabBarMath.buttonSize(density: density) + 4
		)
	}

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		let center = NotificationCenter.default
		center.removeObserver(self)
		if let window {
			for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
				center.addObserver(
					self, selector: #selector(windowKeyChanged), name: name, object: window)
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
				current: layout.scrollOffset, tabMinX: frame.minX - base,
				tabMaxX: frame.maxX - base,
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
			if isNew {
				view.frame = slots[index]
				// A new tab fades in on the insertion timing.
				if animated {
					view.alphaValue = 0
					RiftTabAnimator.setAlpha(view, 1, timing: animation.insertion)
				}
			}
			// After a drop the dropped tab returns on its own timing and the others settle.
			let timing: RiftTabTiming? =
				returningTab == nil
				? nil : (id == returningTab ? animation.tabReturn : animation.returnLayout)
			place(view, slots[index], animated: animated && !isNew, timing: timing)
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
		updateTrack(animated: animated)
		updateChrome()
	}

	/// The track hugs the tabs: the first through the last grown by 2pt (no wider than the strip
	/// plus 4pt), stretched to keep 2pt around a dragged tab, and faded out while there is only
	/// one tab (unless tabs fill the bar).
	private func updateTrack(animated: Bool) {
		guard let resolved else { return }
		let fromClip = CGPoint(x: resolved.trackFrame.minX - 2, y: resolved.trackFrame.minY - 4)
		var frames = resolved.tabFrames
		if let draggedTab, let view = itemViews[draggedTab] {
			frames.append(view.frame.offsetBy(dx: fromClip.x, dy: fromClip.y))
		}
		guard let first = frames.first else {
			trackSurface.alphaValue = 0
			return
		}
		var hull = frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -2, dy: -2)
		if draggedTab == nil {
			hull.size.width = min(hull.width, resolved.trackFrame.width + 4)
		} else {
			// Vertically it follows a quarter of the dragged tab's travel.
			let base = resolved.tabFrames.first.map { $0.insetBy(dx: -2, dy: -2) } ?? hull
			hull.origin.y =
				base.minY + (min(hull.minY - base.minY, 0) + max(hull.maxY - base.maxY, 0)) / 4
			hull.size.height = base.height
		}
		hull = hull.insetBy(dx: trackInset, dy: trackInset)
		// Clipped to the strip the tabs scroll in.
		let strip = resolved.trackFrame.insetBy(dx: -2, dy: -2)
		hull = hull.intersection(strip.insetBy(dx: -RiftTabBarMath.trackOvershoot, dy: -4))
		// The track moves on the geometry timing (at two thirds of its duration).
		var timing = animation.geometry
		timing.duration /= 1.5
		if animated, !trackSurface.frame.isEmpty {
			RiftTabAnimator.setFrame(trackSurface, hull, timing: timing)
		} else {
			trackSurface.frame = hull
		}
		let alpha: CGFloat = tabs.count == 1 && !fillsAvailableSpace ? 0 : 1
		RiftTabAnimator.setAlpha(trackSurface, alpha, timing: animated ? timing : nil)
	}

	private func place(
		_ view: NSView, _ frame: CGRect, animated: Bool, timing: RiftTabTiming? = nil
	) {
		RiftTabAnimator.setFrame(
			view, frame, timing: animated ? (timing ?? animation.geometry) : nil)
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
			hover: looks.hover, density: density, textColor: textColor, windowActive: isWindowActive
		)
		return view
	}

	private var isDark: Bool {
		effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
	}
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
		// White at 11.2% (dark) or black at 8% (light), with a 1pt separator-coloured outline.
		var placeholderStyle = RiftSurfaceStyle()
		placeholderStyle.cornerRadius = RiftTabBarMath.tabCornerRadius
		placeholderStyle.fill = RiftSurfaceFill(
			color: isDark ? NSColor(white: 1, alpha: 0.112) : NSColor(white: 0, alpha: 0.08))
		placeholderStyle.strokes = [RiftSurfaceStroke(color: .separatorColor)]
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
				paneDropIndex == nil
				&& RiftTabBarMath.showsDivider(atTab: index, highlighted: highlighted)
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
			rect: bounds,
			options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
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
		guard let resolved, resolved.maximumScrollOffset > 0 else {
			return super.scrollWheel(with: event)
		}
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
			if let resolved = self.resolved, self.tabs.count > 1 {
				self.heldTabWidth = resolved.tabWidth
			}
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
			RiftCloseConfirmation.Row(id: index, text: "\(entry.0.title) \(entry.1)") {
				[weak self] in
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
		menu.addItem(
			RiftClosureMenuItem(title: "Rename Tab…") { [weak self] in self?.itemRequestsRename(id)
			})
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
		view.layer?.removeAllAnimations()
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
				x: track.minX - scrollOffset, y: track.minY,
				width: max(track.width, contentWidth(resolved)),
				height: track.height))
		view.setFrameOrigin(origin)
		if selectedTab == id { selectionSurface.frame = view.frame }
		updateTrack(animated: false)

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
		returningTab = dragged
		layoutAnimated()
		returningTab = nil
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
			index = RiftTabBarMath.reorderedIndex(
				draggedMidX: inClip.x, current: current, slotMidXs: mids)
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
			springLoadRevision += 1
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

	/// After hovering 0.32s the tab pulses (unless Reduce Motion is on); 0.32s later it opens.
	private func springLoad() {
		guard let id = springLoadedTab else { return }
		let duration = RiftTabBarMath.springLoadPulseDuration
		if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
			itemViews[id]?.pulse(duration: duration)
		}
		springLoadRevision += 1
		let revision = springLoadRevision
		springLoadTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
			[weak self] _ in
			MainActor.assumeIsolated {
				guard let self, self.springLoadRevision == revision, let id = self.springLoadedTab
				else { return }
				self.onSelect?(id)
			}
		}
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

extension RiftTabBarView: RiftTabItemHost {}
