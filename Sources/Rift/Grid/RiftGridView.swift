import AppKit
import RiftCore

/// What a grid cell's content can know about its cell.
public struct RiftGridCellState: Equatable, Sendable {
	public var isSelected = false
	/// Something dragged would land onto this item.
	public var isDropTarget = false
	public var isHovered = false
	/// The grid has the keyboard in the key window (selections are drawn stronger).
	public var isEmphasized = false

	public init() {}
}

/// Adopt in a cell's content view to hear about its cell's state.
@MainActor
public protocol RiftGridCellStateObserving: AnyObject {
	func riftGridCellStateDidChange(_ state: RiftGridCellState)
}

/// A grid of interactive views that can be selected, reordered by dragging, dragged onto one
/// another and dragged between grids.
///
/// - The grid lays its items out in equal cells, left to right and top to bottom. The number of
///   columns follows the width (`metrics.columns = .fitting`) or is fixed.
/// - It is meant to be a scroll view's document view (see `makeScrollView()`): it takes the clip
///   view's width and is as tall as its rows. Only the cells in view have views.
/// - Each item's view comes from `makeItemView`. A press that turns into a drag moves the item;
///   with `forwardsClicksToContent`, a plain click is also passed to the item's view.
/// - The grid never changes `items` on its own account: it reports what the user did
///   (`onMove`, `onInsert`, `onRemove`, `onDropOnto`) and shows the result straight away.
@MainActor
public final class RiftGridView<ItemID: Hashable>: NSView {
	// MARK: Content

	public var items: [ItemID] = [] {
		didSet { if items != oldValue { itemsChanged() } }
	}
	/// Creates the view for an item the first time its cell comes into view.
	public var makeItemView: (ItemID) -> NSView
	public var metrics = RiftGridMetrics() {
		didSet { if metrics != oldValue { relayout(animated: window != nil) } }
	}
	/// The selected items. Setting it does not call `onSelectionChange`.
	public var selection: Set<ItemID> = [] {
		didSet { if selection != oldValue { updateCellStates() } }
	}

	// MARK: Behaviour

	public var allowsMultipleSelection = true
	/// Dragging an item to another place in this grid.
	public var allowsReordering = true
	/// Grids with the same group take each other's items (`nil`: this grid's items stay in it).
	public var dragGroup: String? = "rift.grid"
	/// Draw a rounded highlight behind selected, hovered and drop-target cells.
	public var drawsSelection = true {
		didSet { if drawsSelection != oldValue { updateCellStates() } }
	}
	/// Also pass a plain click (no drag, no modifier keys) on to the item's own view.
	public var forwardsClicksToContent = false
	/// How cells move to their new places (`nil`: no animation).
	public var animation: RiftTabTiming? = RiftTabTiming(0.28, .spring)
	public var theme: RiftThemeSelection? { didSet { if theme != oldValue { updateCellStates() } } }
	/// The corner radius of the cell highlight.
	public var cellCornerRadius: CGFloat = 10 {
		didSet { if cellCornerRadius != oldValue { updateCellStates() } }
	}

	// MARK: Callbacks

	public var onSelectionChange: ((Set<ItemID>) -> Void)?
	/// A double-click, or Return: the selected items in grid order.
	public var onOpen: (([ItemID]) -> Void)?
	/// The user moved these items so that the first is at this index among the others.
	public var onMove: (([ItemID], Int) -> Void)?
	/// Items dragged in from another grid, and the index they were dropped at. Return `true` to
	/// take them (the source grid then gets `onRemove`).
	public var onInsert: (([ItemID], Int) -> Bool)?
	/// These items left for another grid, or were dropped onto an item that took them.
	public var onRemove: (([ItemID]) -> Void)?
	/// Whether the dragged items can be dropped onto an item (a folder, say).
	public var canDropOnto: (([ItemID], ItemID) -> Bool)?
	/// Items were dropped onto an item. Return `true` if they were taken (they are then removed
	/// from the grid they came from).
	public var onDropOnto: (([ItemID], ItemID) -> Bool)?
	/// Items were dropped outside every grid, at this screen point. Without it they go back.
	public var onDragOut: (([ItemID], CGPoint) -> Void)?
	/// The menu for a right-click: on the selection, or on nothing (an empty set).
	public var menuProvider: ((Set<ItemID>) -> NSMenu?)?
	/// A name for each item, for accessibility.
	public var itemLabel: ((ItemID) -> String)?

	// MARK: State

	private var cells: [ItemID: RiftGridCellView] = [:]
	private(set) var gridLayout = RiftGridLayout(count: 0, width: 0)
	private var hoveredItem: ItemID? {
		didSet { if hoveredItem != oldValue { updateCellStates() } }
	}
	private var trackingArea: NSTrackingArea?
	/// The last item clicked or moved to with the keyboard, and where a Shift-range starts.
	private var cursorItem: ItemID?
	private var anchorItem: ItemID?
	private var isReplayingClick = false
	private let bandLayer = CAShapeLayer()

	// Drag state: items taken out of the flow, the open slot, and the item a drop would land on.
	private var liftedItems: Set<ItemID> = []
	private var gapIndex: Int?
	private var ontoItem: ItemID?
	private var pendingDrop: RiftGridDropTarget?

	public init(makeItemView: @escaping (ItemID) -> NSView) {
		self.makeItemView = makeItemView
		super.init(frame: .zero)
		wantsLayer = true
		bandLayer.isHidden = true
		bandLayer.lineWidth = 1
		bandLayer.zPosition = 100
		layer?.addSublayer(bandLayer)
	}

	@available(*, unavailable)
	public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	public override var isFlipped: Bool { true }
	public override var mouseDownCanMoveWindow: Bool { false }
	public override var acceptsFirstResponder: Bool { true }
	public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	/// A scroll view with this grid as its document, scrolling vertically.
	public func makeScrollView() -> NSScrollView {
		let scroll = NSScrollView()
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.autohidesScrollers = true
		scroll.documentView = self
		return scroll
	}

	// MARK: Layout

	/// The items in the flow (everything not lifted by a drag), in order.
	private var flow: [ItemID] {
		liftedItems.isEmpty ? items : items.filter { !liftedItems.contains($0) }
	}

	private var clipView: NSClipView? { superview as? NSClipView }

	public override func viewDidMoveToSuperview() {
		super.viewDidMoveToSuperview()
		NotificationCenter.default.removeObserver(
			self, name: NSView.frameDidChangeNotification, object: nil)
		NotificationCenter.default.removeObserver(
			self, name: NSView.boundsDidChangeNotification, object: nil)
		guard let clipView else { return }
		clipView.postsFrameChangedNotifications = true
		clipView.postsBoundsChangedNotifications = true
		NotificationCenter.default.addObserver(
			self, selector: #selector(clipChanged), name: NSView.frameDidChangeNotification,
			object: clipView)
		NotificationCenter.default.addObserver(
			self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification,
			object: clipView)
		relayout(animated: false)
	}

	@objc private func clipChanged() { relayout(animated: false) }
	@objc private func clipScrolled() { placeCells(animated: false) }

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		NotificationCenter.default.removeObserver(
			self, name: NSWindow.didBecomeKeyNotification, object: nil)
		NotificationCenter.default.removeObserver(
			self, name: NSWindow.didResignKeyNotification, object: nil)
		guard let window else {
			RiftViewRegistry.unregister(self)
			return
		}
		RiftViewRegistry.register(self)
		for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
			NotificationCenter.default.addObserver(
				self, selector: #selector(keyStateChanged), name: name, object: window)
		}
		relayout(animated: false)
	}

	@objc private func keyStateChanged() { updateCellStates() }

	public override func setFrameSize(_ newSize: NSSize) {
		let widthChanged = newSize.width != frame.width
		super.setFrameSize(newSize)
		if widthChanged, clipView == nil { relayout(animated: false) }
	}

	/// Outside a scroll view the grid is as tall as its rows.
	public override var intrinsicContentSize: NSSize {
		NSSize(width: NSView.noIntrinsicMetric, height: gridLayout.contentHeight)
	}

	/// How many slots are laid out: the flow, plus the open slot of a drag.
	private var slotCount: Int { flow.count + (gapIndex == nil ? 0 : 1) }

	private func slot(forFlowIndex index: Int) -> Int {
		guard let gapIndex, index >= gapIndex else { return index }
		return index + 1
	}

	/// Lays the grid out for the current width and items, and sizes it to its rows.
	private func relayout(animated: Bool) {
		let width = clipView?.bounds.width ?? bounds.width
		gridLayout = RiftGridLayout(count: slotCount, width: width, metrics: metrics)
		if let clipView {
			let size = CGSize(
				width: width, height: max(gridLayout.contentHeight, clipView.bounds.height))
			if frame.size != size { super.setFrameSize(size) }
		} else {
			invalidateIntrinsicContentSize()
		}
		placeCells(animated: animated)
	}

	/// Gives every item in view a cell at its slot, and drops the cells that left the view.
	private func placeCells(animated: Bool) {
		let flow = self.flow
		let visible = visibleRect
		let range = gridLayout.visibleIndices(minY: visible.minY, maxY: visible.maxY, overscan: 1)
		var wanted: [ItemID: CGRect] = [:]
		for (index, id) in flow.enumerated() {
			let slot = slot(forFlowIndex: index)
			guard range.contains(slot) else { continue }
			wanted[id] = gridLayout.frame(at: slot)
		}
		let timing = animated ? animation : nil
		for (id, cell) in cells where wanted[id] == nil && !liftedItems.contains(id) {
			cell.removeFromSuperview()
			cells[id] = nil
		}
		for (id, frame) in wanted {
			if let cell = cells[id] {
				RiftTabAnimator.setFrame(cell, frame, timing: timing)
				continue
			}
			let cell = RiftGridCellView(content: makeItemView(id))
			cell.frame = frame
			addSubview(cell)
			cells[id] = cell
			if timing != nil {
				cell.alphaValue = 0
				RiftTabAnimator.setAlpha(cell, 1, timing: RiftTabTiming(0.18))
			}
		}
		updateCellStates()
	}

	private func itemsChanged() {
		let present = Set(items)
		for (id, cell) in cells where !present.contains(id) {
			cell.removeFromSuperview()
			cells[id] = nil
		}
		liftedItems.formIntersection(present)
		if let cursorItem, !present.contains(cursorItem) { self.cursorItem = nil }
		if let anchorItem, !present.contains(anchorItem) { self.anchorItem = nil }
		let kept = selection.intersection(present)
		if kept != selection { setSelection(kept) }
		relayout(animated: window != nil)
	}

	// MARK: Cell states

	private var isEmphasized: Bool {
		window?.isKeyWindow == true && window?.firstResponder === self
	}

	private var accentColor: NSColor {
		theme.map { NSColor.rift(.accent, in: $0) } ?? .controlAccentColor
	}

	private func updateCellStates() {
		let emphasized = isEmphasized
		for (id, cell) in cells {
			var state = RiftGridCellState()
			state.isSelected = selection.contains(id)
			state.isDropTarget = ontoItem == id
			state.isHovered = hoveredItem == id
			state.isEmphasized = emphasized
			cell.isHidden = liftedItems.contains(id)
			cell.apply(
				state, drawsHighlight: drawsSelection, accent: accentColor,
				cornerRadius: cellCornerRadius, label: itemLabel?(id))
		}
	}

	public override func becomeFirstResponder() -> Bool {
		defer { updateCellStates() }
		return super.becomeFirstResponder()
	}

	public override func resignFirstResponder() -> Bool {
		defer { updateCellStates() }
		return super.resignFirstResponder()
	}

	public override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		updateCellStates()
	}

	// MARK: Selection

	private func setSelection(_ new: Set<ItemID>) {
		guard new != selection else { return }
		selection = new
		onSelectionChange?(new)
	}

	private var orderedSelection: [ItemID] { items.filter(selection.contains) }

	/// Scrolls an item's cell into view.
	public func scrollToItem(_ id: ItemID) {
		guard let index = flow.firstIndex(of: id) else { return }
		scrollToVisible(gridLayout.frame(at: slot(forFlowIndex: index)).insetBy(dx: 0, dy: -4))
	}

	private func moveCursor(_ direction: RiftDirection, extending: Bool) {
		let flow = self.flow
		guard !flow.isEmpty else { return }
		guard let current = cursorItem.flatMap(flow.firstIndex(of:)) else {
			select(flow[0], extending: false)
			return
		}
		guard let next = gridLayout.index(from: current, moving: direction), next < flow.count
		else { return }
		select(flow[next], extending: extending)
	}

	private func select(_ id: ItemID, extending: Bool) {
		if extending, allowsMultipleSelection, let anchor = anchorItem {
			setSelection(Set(RiftGridMath.range(from: anchor, to: id, in: flow)))
		} else {
			anchorItem = id
			setSelection([id])
		}
		cursorItem = id
		scrollToItem(id)
	}

	public override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

	public override func moveLeft(_ sender: Any?) { moveCursor(.left, extending: false) }
	public override func moveRight(_ sender: Any?) { moveCursor(.right, extending: false) }
	public override func moveUp(_ sender: Any?) { moveCursor(.up, extending: false) }
	public override func moveDown(_ sender: Any?) { moveCursor(.down, extending: false) }
	public override func moveLeftAndModifySelection(_ sender: Any?) {
		moveCursor(.left, extending: true)
	}
	public override func moveRightAndModifySelection(_ sender: Any?) {
		moveCursor(.right, extending: true)
	}
	public override func moveUpAndModifySelection(_ sender: Any?) {
		moveCursor(.up, extending: true)
	}
	public override func moveDownAndModifySelection(_ sender: Any?) {
		moveCursor(.down, extending: true)
	}
	public override func selectAll(_ sender: Any?) {
		guard allowsMultipleSelection else { return }
		setSelection(Set(items))
	}
	public override func insertNewline(_ sender: Any?) {
		let chosen = orderedSelection
		if !chosen.isEmpty { onOpen?(chosen) }
	}
	public override func cancelOperation(_ sender: Any?) { setSelection([]) }

	// MARK: Hover

	public override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea { removeTrackingArea(trackingArea) }
		let area = NSTrackingArea(
			rect: .zero,
			options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
			owner: self, userInfo: nil)
		addTrackingArea(area)
		trackingArea = area
	}

	public override func mouseMoved(with event: NSEvent) { updateHover(event) }
	public override func mouseEntered(with event: NSEvent) { updateHover(event) }
	public override func mouseExited(with event: NSEvent) { hoveredItem = nil }

	private func updateHover(_ event: NSEvent) {
		hoveredItem = item(at: convert(event.locationInWindow, from: nil))
	}

	/// The item whose cell is at a point in the grid.
	public func item(at point: CGPoint) -> ItemID? {
		let flow = self.flow
		guard let slot = gridLayout.index(at: point) else { return nil }
		if let gapIndex {
			if slot == gapIndex { return nil }
			let index = slot > gapIndex ? slot - 1 : slot
			return index < flow.count ? flow[index] : nil
		}
		return slot < flow.count ? flow[slot] : nil
	}

	/// The views of the items that have cells right now (the ones in or near view).
	public var itemViews: [NSView] { cells.values.map(\.content) }

	/// An item's cell frame, in the grid's coordinates.
	public func frame(of id: ItemID) -> CGRect? {
		flow.firstIndex(of: id).map { gridLayout.frame(at: slot(forFlowIndex: $0)) }
	}

	// MARK: Mouse

	// The grid takes every click itself (to select and to drag); item views still get hover, and
	// plain clicks when `forwardsClicksToContent` is on.
	public override func hitTest(_ point: NSPoint) -> NSView? {
		guard !isHidden else { return nil }
		if isReplayingClick { return super.hitTest(point) }
		return frame.contains(point) ? self : nil
	}

	public override func menu(for event: NSEvent) -> NSMenu? {
		let point = convert(event.locationInWindow, from: nil)
		if let id = item(at: point) {
			if !selection.contains(id) {
				anchorItem = id
				cursorItem = id
				setSelection([id])
			}
		} else {
			setSelection([])
		}
		return menuProvider?(selection)
	}

	public override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		let start = convert(event.locationInWindow, from: nil)
		let modifiers = event.modifierFlags.intersection([.command, .shift])
		guard let id = item(at: start) else {
			trackSelectionRectangle(from: event)
			return
		}
		var collapsesOnMouseUp = false
		if modifiers.contains(.command), allowsMultipleSelection {
			setSelection(selection.symmetricDifference([id]))
			anchorItem = id
		} else if modifiers.contains(.shift), allowsMultipleSelection, let anchor = anchorItem {
			setSelection(Set(RiftGridMath.range(from: anchor, to: id, in: flow)))
		} else if selection.contains(id) {
			collapsesOnMouseUp = selection.count > 1
		} else {
			anchorItem = id
			setSelection([id])
		}
		cursorItem = id
		guard let window else { return }
		let canDrag = allowsReordering || dragGroup != nil || onDragOut != nil
		var session: RiftGridDragSession<ItemID>?
		NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 0.05)
		defer { NSEvent.stopPeriodicEvents() }
		while let next = window.nextEvent(matching: [
			.leftMouseDragged, .leftMouseUp, .keyDown, .periodic,
		]) {
			switch next.type {
			case .leftMouseDragged:
				if session == nil, canDrag {
					let here = convert(next.locationInWindow, from: nil)
					guard hypot(here.x - start.x, here.y - start.y) >= 4 else { continue }
					let dragged = selection.contains(id) ? orderedSelection : [id]
					session = RiftGridDragSession(
						source: self, items: dragged, primary: id, grabPoint: start)
				}
				session?.move(with: next)
			case .periodic:
				session?.autoscroll()
			case .keyDown:
				guard next.keyCode == 53 else { continue }  // Escape
				session?.cancel()
				return
			case .leftMouseUp:
				if let session {
					session.drop()
					return
				}
				if collapsesOnMouseUp, modifiers.isEmpty {
					anchorItem = id
					setSelection([id])
				}
				if next.clickCount == 2, modifiers.isEmpty {
					onOpen?(orderedSelection)
				} else if forwardsClicksToContent, modifiers.isEmpty {
					isReplayingClick = true
					window.sendEvent(event)
					window.sendEvent(next)
					isReplayingClick = false
				}
				return
			default:
				continue
			}
		}
	}

	/// Dragging from empty space draws a rectangle that selects the cells it touches.
	private func trackSelectionRectangle(from event: NSEvent) {
		let start = convert(event.locationInWindow, from: nil)
		let extending =
			allowsMultipleSelection
			&& !event.modifierFlags.intersection([.command, .shift]).isEmpty
		let base = extending ? selection : []
		if !extending { setSelection([]) }
		guard allowsMultipleSelection, let window else { return }
		defer { bandLayer.isHidden = true }
		var last = event
		NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 0.05)
		defer { NSEvent.stopPeriodicEvents() }
		while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
			if next.type == .leftMouseUp { return }
			if next.type == .leftMouseDragged { last = next }
			autoscroll(with: last)
			let here = convert(last.locationInWindow, from: nil)
			let rect = CGRect(
				x: min(start.x, here.x), y: min(start.y, here.y), width: abs(here.x - start.x),
				height: abs(here.y - start.y))
			let flow = self.flow
			let touched = gridLayout.indices(intersecting: rect).compactMap {
				$0 < flow.count ? flow[$0] : nil
			}
			setSelection(base.union(touched))
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			effectiveAppearance.performAsCurrentDrawingAppearance {
				bandLayer.fillColor = accentColor.withAlphaComponent(0.12).cgColor
				bandLayer.strokeColor = accentColor.withAlphaComponent(0.6).cgColor
			}
			bandLayer.path = CGPath(rect: rect.insetBy(dx: 0.5, dy: 0.5), transform: nil)
			bandLayer.isHidden = rect.width < 2 && rect.height < 2
			CATransaction.commit()
		}
	}

	// MARK: Drags (called by the drag session)

	/// A snapshot of an item's cell, for the drag preview.
	func snapshot(of id: ItemID) -> NSImage? {
		guard let cell = cells[id], cell.bounds.width > 0, cell.bounds.height > 0,
			let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds)
		else { return nil }
		cell.cacheDisplay(in: cell.bounds, to: rep)
		let image = NSImage(size: cell.bounds.size)
		image.addRepresentation(rep)
		return image
	}

	/// Takes the dragged items out of the flow; the others close up.
	func liftItems(_ ids: [ItemID]) {
		liftedItems = Set(ids)
		hoveredItem = nil
		relayout(animated: true)
	}

	/// Whether this grid takes a drag from `source`, and where it would land. Shows the open slot
	/// or the drop-target highlight.
	func dragMoved(_ ids: [ItemID], from source: RiftGridView<ItemID>, windowPoint: CGPoint) -> Bool
	{
		let point = convert(windowPoint, from: nil)
		let isOwn = source === self
		let takesBetween = isOwn ? allowsReordering : onInsert != nil
		let flow = self.flow
		// The target is worked out on the layout without the open slot, so opening the slot
		// under the pointer can't change the answer.
		let base = RiftGridLayout(
			count: flow.count, width: gridLayout.width, metrics: metrics)
		var target = base.dropTarget(at: point) { index in
			index < flow.count && (self.canDropOnto?(ids, flow[index]) ?? false)
		}
		if case .between = target, !takesBetween {
			// Onto-only: the middle half rule still applies, so only a direct hit counts.
			target = .between(-1)
		}
		switch target {
		case .onto(let index):
			setDragTarget(gap: nil, onto: flow[index], drop: target)
		case .between(let index) where index >= 0:
			setDragTarget(gap: index, onto: nil, drop: target)
		default:
			setDragTarget(gap: nil, onto: nil, drop: nil)
			return false
		}
		return true
	}

	func dragExited() { setDragTarget(gap: nil, onto: nil, drop: nil) }

	private func setDragTarget(gap: Int?, onto: ItemID?, drop: RiftGridDropTarget?) {
		pendingDrop = drop
		let changed = gap != gapIndex
		gapIndex = gap
		if onto != ontoItem {
			ontoItem = onto
			updateCellStates()
		}
		if changed { relayout(animated: true) }
	}

	/// Applies the drop the last `dragMoved` showed. Returns whether the items were taken.
	func performDrop(_ ids: [ItemID], from source: RiftGridView<ItemID>, cellOrigin: CGPoint?)
		-> Bool
	{
		let drop = pendingDrop
		let flow = self.flow
		setDragTarget(gap: nil, onto: nil, drop: nil)
		guard let drop else { return false }
		switch drop {
		case .onto(let index):
			guard index < flow.count, onDropOnto?(ids, flow[index]) == true else { return false }
			source.itemsLeft(ids)
			return true
		case .between(let index):
			if source === self {
				guard allowsReordering else { return false }
				let moved = RiftGridMath.moving(Set(ids), in: items, to: index)
				land(ids, at: cellOrigin)
				liftedItems = []
				if moved != items {
					items = moved
					onMove?(ids, index)
				} else {
					relayout(animated: true)
				}
				return true
			}
			guard onInsert?(ids, index) == true else { return false }
			var updated = items.filter { !ids.contains($0) }
			updated.insert(contentsOf: ids, at: min(index, updated.count))
			items = updated
			land(ids, at: cellOrigin)
			source.itemsLeft(ids)
			return true
		}
	}

	/// Starts the dropped item's cell where the preview was, so it glides into its slot.
	private func land(_ ids: [ItemID], at origin: CGPoint?) {
		guard let origin, let first = ids.first else { return }
		if cells[first] == nil, items.contains(first) {
			let cell = RiftGridCellView(content: makeItemView(first))
			addSubview(cell)
			cells[first] = cell
		}
		guard let cell = cells[first] else { return }
		cell.layer?.removeAllAnimations()
		cell.frame = CGRect(origin: origin, size: gridLayout.cellSize)
		addSubview(cell, positioned: .above, relativeTo: nil)
	}

	/// The items were taken somewhere else: they leave this grid.
	private func itemsLeft(_ ids: [ItemID]) {
		let gone = Set(ids)
		liftedItems = []
		items = items.filter { !gone.contains($0) }
		onRemove?(ids)
	}

	/// The drag ended without a drop: the items go back to their places.
	func dragEnded(returning ids: [ItemID], cellOrigin: CGPoint?) {
		setDragTarget(gap: nil, onto: nil, drop: nil)
		land(ids, at: cellOrigin)
		liftedItems = []
		relayout(animated: true)
	}

	/// Every grid in `group` that could take a drop.
	static func grids(in group: String) -> [RiftGridView<ItemID>] {
		RiftViewRegistry.views(of: RiftGridView<ItemID>.self).filter {
			$0.dragGroup == group && $0.window?.isVisible == true && !$0.isHiddenOrHasHiddenAncestor
		}
	}

	// MARK: Accessibility

	public override func isAccessibilityElement() -> Bool { true }
	public override func accessibilityRole() -> NSAccessibility.Role? { .list }
	public override func accessibilityChildren() -> [Any]? {
		flow.compactMap { cells[$0] }
	}
}

/// One cell: a highlight behind the item's own view.
final class RiftGridCellView: RiftFlippedView {
	let content: NSView
	private let highlight = CALayer()
	private var state = RiftGridCellState()
	private var label: String?

	init(content: NSView) {
		self.content = content
		super.init(frame: .zero)
		wantsLayer = true
		highlight.cornerCurve = .continuous
		layer?.addSublayer(highlight)
		content.translatesAutoresizingMaskIntoConstraints = true
		content.autoresizingMask = [.width, .height]
		addSubview(content)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	override func layout() {
		super.layout()
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		highlight.frame = bounds
		CATransaction.commit()
		content.frame = bounds
	}

	func apply(
		_ state: RiftGridCellState, drawsHighlight: Bool, accent: NSColor, cornerRadius: CGFloat,
		label: String?
	) {
		self.label = label
		let changed = state != self.state
		self.state = state
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		effectiveAppearance.performAsCurrentDrawingAppearance {
			var fill = NSColor.clear
			var border = NSColor.clear
			if drawsHighlight {
				if state.isDropTarget {
					fill = accent.withAlphaComponent(0.18)
					border = accent
				} else if state.isSelected {
					fill =
						state.isEmphasized
						? accent.withAlphaComponent(0.26)
						: NSColor.labelColor.withAlphaComponent(0.14)
				} else if state.isHovered {
					fill = NSColor.labelColor.withAlphaComponent(0.05)
				}
			}
			highlight.backgroundColor = fill.cgColor
			highlight.borderColor = border.cgColor
			highlight.borderWidth = state.isDropTarget && drawsHighlight ? 2 : 0
			highlight.cornerRadius = cornerRadius
		}
		CATransaction.commit()
		if changed {
			(content as? RiftGridCellStateObserving)?.riftGridCellStateDidChange(state)
		}
	}

	override func isAccessibilityElement() -> Bool { true }
	override func accessibilityRole() -> NSAccessibility.Role? { .cell }
	override func accessibilityLabel() -> String? { label }
	override func isAccessibilitySelected() -> Bool { state.isSelected }
}

/// One drag of grid items: a floating preview that follows the pointer, the grid under it that
/// would take the drop, and the drop itself.
@MainActor
final class RiftGridDragSession<ItemID: Hashable> {
	private let source: RiftGridView<ItemID>
	private let items: [ItemID]
	private let panel: NSPanel
	/// Where in the cell the press was (y down).
	private let grab: CGPoint
	private let cellSize: CGSize
	private weak var target: RiftGridView<ItemID>?
	private var lastEvent: NSEvent?

	init(source: RiftGridView<ItemID>, items: [ItemID], primary: ItemID, grabPoint: CGPoint) {
		self.source = source
		self.items = items
		let frame = source.frame(of: primary) ?? CGRect(origin: grabPoint, size: .zero)
		cellSize = frame.size
		grab = CGPoint(x: grabPoint.x - frame.minX, y: grabPoint.y - frame.minY)
		panel = NSPanel(
			contentRect: CGRect(origin: .zero, size: frame.size),
			styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false
		panel.level = .floating
		panel.ignoresMouseEvents = true
		panel.isReleasedWhenClosed = false
		panel.collectionBehavior = [.transient, .ignoresCycle]
		let holder = NSView(frame: CGRect(origin: .zero, size: frame.size))
		holder.wantsLayer = true
		let image = NSImageView(frame: holder.bounds)
		image.image = source.snapshot(of: primary)
		image.imageScaling = .scaleAxesIndependently
		image.alphaValue = 0.9
		holder.addSubview(image)
		if items.count > 1 {
			// How many items are moving, as a badge on the preview's corner.
			let badge = NSTextField(labelWithString: "\(items.count)")
			badge.font = .systemFont(ofSize: 11, weight: .semibold)
			badge.textColor = .white
			badge.alignment = .center
			badge.wantsLayer = true
			badge.layer?.backgroundColor = NSColor.systemRed.cgColor
			let width = max(20, badge.intrinsicContentSize.width + 10)
			badge.frame = CGRect(
				x: frame.width - width - 4, y: frame.height - 24, width: width, height: 20)
			badge.layer?.cornerRadius = 10
			holder.addSubview(badge)
		}
		panel.contentView = holder
		source.liftItems(items)
	}

	private func screenPoint(_ event: NSEvent) -> CGPoint {
		event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
	}

	func move(with event: NSEvent) {
		lastEvent = event
		update(screenPoint(event))
	}

	/// Keeps scrolling the grid under a pointer held near its edge.
	func autoscroll() {
		guard let lastEvent, let target, target.window === lastEvent.window else { return }
		if target.autoscroll(with: lastEvent) { update(screenPoint(lastEvent)) }
	}

	private func update(_ screen: CGPoint) {
		panel.setFrameOrigin(
			CGPoint(x: screen.x - grab.x, y: screen.y - (cellSize.height - grab.y)))
		if !panel.isVisible { panel.orderFront(nil) }
		let found = grid(at: screen)
		if let old = target, old !== found { old.dragExited() }
		target = nil
		guard let found, let window = found.window else { return }
		if found.dragMoved(
			items, from: source, windowPoint: window.convertPoint(fromScreen: screen))
		{
			target = found
		}
	}

	/// The grid under a screen point: in the source's group, in the frontmost window there, and
	/// not covered by another view.
	private func grid(at screen: CGPoint) -> RiftGridView<ItemID>? {
		var candidates = [source]
		if let group = source.dragGroup {
			candidates += RiftGridView<ItemID>.grids(in: group).filter { $0 !== source }
		}
		let order = NSApp.orderedWindows
		func rank(_ grid: RiftGridView<ItemID>) -> Int {
			grid.window.flatMap(order.firstIndex(of:)) ?? .max
		}
		for grid in candidates.sorted(by: { rank($0) < rank($1) }) {
			guard let window = grid.window, window.frame.contains(screen),
				let content = window.contentView
			else { continue }
			let point = window.convertPoint(fromScreen: screen)
			let hit = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
			if hit === grid { return grid }
			// The frontmost window under the pointer decides; a grid behind it gets nothing.
			return nil
		}
		return nil
	}

	/// Where the preview is, as a cell origin in `grid`.
	private func cellOrigin(in grid: RiftGridView<ItemID>) -> CGPoint? {
		guard let window = grid.window else { return nil }
		let frame = panel.frame
		// The panel's top-left corner, in the grid's flipped coordinates.
		let top = window.convertPoint(fromScreen: CGPoint(x: frame.minX, y: frame.maxY))
		return grid.convert(top, from: nil)
	}

	func drop() {
		let screen = lastEvent.map(screenPoint) ?? NSEvent.mouseLocation
		defer { panel.orderOut(nil) }
		if let target, target.performDrop(items, from: source, cellOrigin: cellOrigin(in: target)) {
			return
		}
		target?.dragExited()
		if target == nil, let onDragOut = source.onDragOut, grid(at: screen) == nil {
			source.dragEnded(returning: items, cellOrigin: nil)
			onDragOut(items, screen)
			return
		}
		source.dragEnded(returning: items, cellOrigin: cellOrigin(in: source))
	}

	func cancel() {
		target?.dragExited()
		panel.orderOut(nil)
		source.dragEnded(returning: items, cellOrigin: cellOrigin(in: source))
	}
}
