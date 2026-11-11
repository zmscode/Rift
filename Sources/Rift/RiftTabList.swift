import AppKit
import RiftCore

/// Tabs as rows in a sidebar: 30pt rows (scaled by the text size) under a glass selection that
/// slides between them, with the bar's hover, close, rename, menu, reorder, tear-off and pane drops.
///
/// - Click a row to select it; click the selected row again to rename it.
/// - Drag a row past 4pt to move it; dropped outside every window, it is torn off.
/// - Hover a dragged pane over a row for 0.32s and it flashes, then opens; drop the pane between
///   rows to make it a new tab there.
@MainActor
public final class RiftTabListView<ID: Hashable>: NSView, RiftTabItemHost, RiftPaneDropAccepting {
	// MARK: Content

	public var tabs: [RiftTab<ID>] = [] {
		didSet { if tabs != oldValue { tabsChanged(from: oldValue) } }
	}
	public var selectedTab: ID? {
		didSet {
			guard selectedTab != oldValue else { return }
			animatesNextLayout = window != nil
			needsLayout = true
			updateChrome()
		}
	}

	// MARK: Options

	public var density: RiftChromeDensity = .comfortable {
		didSet { if density != oldValue { restyle() } }
	}
	public var textSize: RiftSidebarTextSize = .medium {
		didSet {
			if textSize != oldValue {
				restyle()
				invalidateIntrinsicContentSize()
			}
		}
	}
	public var surfaces: RiftTabSurfaces = .modern(.comfortable) {
		didSet { if surfaces != oldValue { restyle() } }
	}
	public var theme: RiftThemeSelection? { didSet { if theme != oldValue { restyle() } } }
	public var animation: RiftTabAnimation = .standard
	public var paneDropGroup: String?

	// MARK: Callbacks

	public var onSelect: ((ID) -> Void)?
	public var onClose: ((ID) -> Void)?
	public var onCloseOthers: ((ID) -> Void)?
	public var onMove: ((ID, Int) -> Void)?
	public var onRename: ((ID, String) -> Void)?
	public var onTearOff: ((ID, CGPoint) -> Void)?
	public var onPaneDrop: ((AnyHashable, Int) -> Bool)?

	// MARK: State

	private let selectionSurface = RiftSurfaceStackView()
	private let placeholder = RiftSurfaceStackView()
	private var itemViews: [ID: RiftTabItemView<ID>] = [:]
	private var rowFrames: [CGRect] = []
	private var animatesNextLayout = false
	private var hoveredTab: ID? { didSet { if hoveredTab != oldValue { updateChrome() } } }
	private var trackingArea: NSTrackingArea?
	private let confirmation = RiftCloseConfirmation()

	private var draggedTab: ID?
	private var returningTab: ID?
	private var dragOrder: [ID]?
	private var dragOriginalOrder: [ID] = []
	private var dragStartPointer: CGPoint = .zero
	private var dragStartOrigin: CGPoint = .zero

	private var paneDropIndex: Int?
	private var springLoadedTab: ID?
	private var springLoadTimer: Timer?
	private var springLoadRevision = 0

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		addSubview(placeholder)
		placeholder.isHidden = true
		addSubview(selectionSurface)
		restyle()
		RiftViewRegistry.register(self)
		setAccessibilityElement(true)
		setAccessibilityRole(.tabGroup)
		setAccessibilityLabel("Tabs")
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	public override var isFlipped: Bool { true }
	public override var mouseDownCanMoveWindow: Bool { false }

	private var rowHeight: CGFloat { RiftTabListMath.rowHeight(textSize) }

	/// As tall as its rows (plus a slot while a pane is dropped between them).
	public override var intrinsicContentSize: NSSize {
		let rows = tabs.count + (paneDropIndex == nil ? 0 : 1)
		return NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows) * rowHeight)
	}

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		NotificationCenter.default.removeObserver(self)
		if let window {
			for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
				NotificationCenter.default.addObserver(
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
		let frames = RiftTabListMath.rowFrames(
			count: slotCount, width: bounds.width, top: 0, height: rowHeight,
			inset: RiftTabListMath.sideInset(density: density))
		var slots = frames
		let animated = animatesNextLayout
		animatesNextLayout = false
		if let index = paneDropIndex, slots.indices.contains(index) {
			let frame = slots.remove(at: index)
			if placeholder.isHidden {
				placeholder.frame = frame.insetBy(dx: 0, dy: frame.height / 2)
				placeholder.isHidden = false
			}
			var style = placeholder.style
			style.cornerRadius = RiftTabBarMath.placeholderCornerRadius(frame.size)
			placeholder.style = style
			RiftTabAnimator.setFrame(placeholder, frame, timing: animation.geometry)
		} else {
			placeholder.isHidden = true
		}
		rowFrames = slots
		for (index, id) in order.enumerated() {
			guard let view = itemViews[id], slots.indices.contains(index) else { continue }
			if id == draggedTab {
				view.setFrameSize(slots[index].size)
				continue
			}
			let isNew = view.frame.isEmpty
			if isNew {
				view.frame = slots[index]
				if animated {
					view.alphaValue = 0
					RiftTabAnimator.setAlpha(view, 1, timing: animation.insertion)
				}
			}
			let timing: RiftTabTiming? =
				returningTab == nil
				? animation.geometry
				: (id == returningTab ? animation.tabReturn : animation.returnLayout)
			RiftTabAnimator.setFrame(view, slots[index], timing: animated && !isNew ? timing : nil)
		}
		if let selectedTab, let view = itemViews[selectedTab],
			let index = order.firstIndex(of: selectedTab), slots.indices.contains(index)
		{
			selectionSurface.isHidden = false
			let target = selectedTab == draggedTab ? view.frame : slots[index]
			var style = selectionSurface.style
			style.cornerRadius = min(
				(RiftTabBarMath.tabCornerRadius * RiftTabListMath.scale(textSize)).rounded(.down),
				target.height / 2)
			selectionSurface.style = style
			if selectionSurface.frame.isEmpty { selectionSurface.frame = target }
			RiftTabAnimator.setFrame(
				selectionSurface, target,
				timing: animated && selectedTab != draggedTab ? animation.geometry : nil)
		} else {
			selectionSurface.isHidden = true
		}
		updateChrome()
	}

	private func layoutAnimated() {
		animatesNextLayout = true
		needsLayout = true
		layoutSubtreeIfNeeded()
	}

	// MARK: Tabs and looks

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
		if let draggedTab, !ids.contains(draggedTab) {
			endTabDrag(nil, screenPoint: nil, cancelled: true)
		}
		if dragOrder != nil { dragOrder = dragOrder?.filter(ids.contains) }
		if old.map(\.id) != tabs.map(\.id) { animatesNextLayout = window != nil && !old.isEmpty }
		invalidateIntrinsicContentSize()
		needsLayout = true
	}

	private func makeItemView(_ id: ID) -> RiftTabItemView<ID> {
		let view = RiftTabItemView<ID>(id: id)
		view.bar = self
		view.isVertical = true
		view.scale = RiftTabListMath.scale(textSize)
		addSubview(view, positioned: .above, relativeTo: selectionSurface)
		itemViews[id] = view
		view.applyLooks(
			hover: looks.hover, density: density, textColor: textColor, windowActive: isWindowActive
		)
		return view
	}

	private var isDark: Bool {
		effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
	}
	private var isWindowActive: Bool { window?.isKeyWindow ?? true }
	private var looks: RiftTabSurfaces.Looks {
		(theme.map { surfaces.themed($0) } ?? surfaces).looks(isDark: isDark)
	}
	private var textColor: NSColor { theme.map { .rift(.content, in: $0) } ?? .labelColor }

	private func restyle() {
		let looks = self.looks
		selectionSurface.style = isWindowActive ? looks.selection : looks.inactiveWindowSelection
		var placeholderStyle = RiftSurfaceStyle()
		placeholderStyle.cornerRadius = RiftTabBarMath.tabCornerRadius
		placeholderStyle.fill = RiftSurfaceFill(
			color: isDark ? NSColor(white: 1, alpha: 0.112) : NSColor(white: 0, alpha: 0.08))
		placeholderStyle.strokes = [RiftSurfaceStroke(color: .separatorColor)]
		placeholder.style = placeholderStyle
		for view in itemViews.values {
			view.scale = RiftTabListMath.scale(textSize)
			view.applyLooks(
				hover: looks.hover, density: density, textColor: textColor,
				windowActive: isWindowActive)
		}
		needsLayout = true
	}

	private func updateChrome() {
		for (id, view) in itemViews {
			view.showsDivider = false
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
	public override func mouseExited(with event: NSEvent) { hoveredTab = nil }

	private func updateHover(_ event: NSEvent) {
		guard draggedTab == nil else { return }
		hoveredTab = tab(at: convert(event.locationInWindow, from: nil))
	}

	private func tab(at point: CGPoint) -> ID? {
		itemViews.first { $0.value.frame.contains(point) }?.key
	}

	// MARK: Item host

	func itemClicked(_ id: ID) {
		if selectedTab != id { onSelect?(id) }
	}

	func itemRenamed(_ id: ID, to title: String) {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != tabs.first(where: { $0.id == id })?.title else { return }
		onRename?(id, trimmed)
	}

	func itemClose(_ id: ID) {
		guard let tab = tabs.first(where: { $0.id == id }), tab.isClosable else { return }
		let close = { [weak self] in self?.onClose?(id) ?? () }
		guard let activity = tab.activity else { return close() }
		presentConfirmation(.tab, busy: [(tab, activity)], spotlight: id, confirm: close)
	}

	private func itemCloseOthers(_ id: ID) {
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
			RiftClosureMenuItem(title: "Rename Tab…") { [weak self] in
				self?.itemViews[id]?.beginRenaming()
			})
		menu.addItem(.separator())
		let up = RiftClosureMenuItem(title: "Move Tab Up") { [weak self] in
			self?.onMove?(id, index - 1)
		}
		up.isEnabled = index > 0
		menu.addItem(up)
		let down = RiftClosureMenuItem(title: "Move Tab Down") { [weak self] in
			self?.onMove?(id, index + 1)
		}
		down.isEnabled = index + 1 < order.count
		menu.addItem(down)
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

	// MARK: Row drag

	func beginTabDrag(_ id: ID, pointer: CGPoint) {
		guard let view = itemViews[id] else { return }
		hoveredTab = nil
		view.layer?.removeAllAnimations()
		draggedTab = id
		dragOriginalOrder = tabs.map(\.id)
		dragOrder = dragOriginalOrder
		dragStartPointer = convert(pointer, from: nil)
		dragStartOrigin = view.frame.origin
		if selectedTab != id { onSelect?(id) }
		updateChrome()
	}

	func moveTabDrag(_ id: ID, pointer: CGPoint) {
		guard draggedTab == id, var order = dragOrder, let view = itemViews[id],
			let first = rowFrames.first, let last = rowFrames.last
		else { return }
		// The row follows the pointer along the list, resisting past either end (as the bar's
		// tabs do along theirs); sideways it gives a little.
		let lane = first.union(last)
		let origin = RiftTabBarMath.draggedOrigin(
			pointer: convert(pointer, from: nil), startPointer: dragStartPointer,
			startOrigin: dragStartOrigin, size: view.frame.size, track: lane)
		view.setFrameOrigin(origin)
		if selectedTab == id { selectionSurface.frame = view.frame }
		guard let current = order.firstIndex(of: id) else { return }
		let target = RiftTabBarMath.reorderedIndex(
			draggedMidX: view.frame.midY, current: current, slotMidXs: rowFrames.map(\.midY))
		if target != current {
			order.remove(at: current)
			order.insert(id, at: target)
			dragOrder = order
			layoutAnimated()
		}
	}

	func endTabDrag(_ id: ID?, screenPoint: CGPoint?, cancelled: Bool) {
		guard let dragged = draggedTab else { return }
		let order = dragOrder ?? dragOriginalOrder
		let outsideWindows = screenPoint.map { point in
			NSApp.window(
				withWindowNumber: NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0))
				== nil
		}
		draggedTab = nil
		dragOrder = nil
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
		returningTab = dragged
		layoutAnimated()
		returningTab = nil
	}

	// MARK: Pane drops

	func paneDragMoved(to point: CGPoint, pane: AnyHashable) -> Bool {
		guard onPaneDrop != nil, bounds.contains(point) else {
			paneDragExited()
			return false
		}
		let mids = RiftTabListMath.rowFrames(
			count: tabs.count + (paneDropIndex == nil ? 0 : 1), width: bounds.width, top: 0,
			height: rowHeight, inset: RiftTabListMath.sideInset(density: density)
		).map(\.midY)
		let index =
			paneDropIndex.map {
				RiftTabBarMath.reorderedIndex(draggedMidX: point.y, current: $0, slotMidXs: mids)
			} ?? tabs.filter { itemViews[$0.id].map { $0.frame.midY < point.y } ?? false }.count
		if index != paneDropIndex {
			paneDropIndex = index
			invalidateIntrinsicContentSize()
			layoutAnimated()
		}
		let hovered = tab(at: point)
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
		springLoadRevision += 1
		springLoadTimer?.invalidate()
		springLoadTimer = nil
		springLoadedTab = nil
		guard paneDropIndex != nil else { return }
		paneDropIndex = nil
		invalidateIntrinsicContentSize()
		layoutAnimated()
	}

	func acceptPaneDrop(_ pane: AnyHashable) -> Bool {
		let index = min(paneDropIndex ?? tabs.count, tabs.count)
		paneDragExited()
		return onPaneDrop?(pane, index) ?? false
	}
}
