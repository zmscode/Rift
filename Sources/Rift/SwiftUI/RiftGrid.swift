import AppKit
import RiftCore
import SwiftUI

/// What a grid cell's SwiftUI content gets to build itself. Each value is observed on its own,
/// so a cell is rebuilt only for the values it reads.
@MainActor
@Observable
public final class RiftGridCell<ID: Hashable> {
	public let id: ID
	public fileprivate(set) var isSelected = false
	/// Something dragged would land onto this item.
	public fileprivate(set) var isDropTarget = false
	public fileprivate(set) var isHovered = false
	/// The grid has the keyboard in the key window.
	public fileprivate(set) var isEmphasized = false
	/// Bumped when the grid's SwiftUI parent updates, so content that captures the parent's state
	/// is rebuilt.
	fileprivate var revision = 0
	/// The last revision written. Kept outside observation: reading `revision` while SwiftUI
	/// updates the grid would make that update depend on the value it is about to change.
	@ObservationIgnored fileprivate var lastRevision = 0

	init(id: ID) { self.id = id }
}

private struct RiftGridCellRoot<ID: Hashable, Content: View>: View {
	let cell: RiftGridCell<ID>
	let content: (RiftGridCell<ID>) -> Content

	var body: some View {
		_ = cell.revision
		return content(cell)
	}
}

/// Hosts one cell's SwiftUI content and forwards its cell's state.
final class RiftGridHostedCell<ID: Hashable>: NSHostingView<AnyView>, RiftGridCellStateObserving {
	let cell: RiftGridCell<ID>

	init(cell: RiftGridCell<ID>, root: AnyView) {
		self.cell = cell
		super.init(rootView: root)
		// The grid sizes the cell; the content never sizes the hosting view.
		sizingOptions = []
	}

	@available(*, unavailable)
	required init(rootView: AnyView) { fatalError() }

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func riftGridCellStateDidChange(_ state: RiftGridCellState) {
		if cell.isSelected != state.isSelected { cell.isSelected = state.isSelected }
		if cell.isDropTarget != state.isDropTarget { cell.isDropTarget = state.isDropTarget }
		if cell.isHovered != state.isHovered { cell.isHovered = state.isHovered }
		if cell.isEmphasized != state.isEmphasized { cell.isEmphasized = state.isEmphasized }
	}

	func refresh() {
		cell.lastRevision &+= 1
		cell.revision = cell.lastRevision
	}
}

/// A scrolling grid of interactive views for SwiftUI (see `RiftGridView`): select them, drag
/// them to reorder, onto one another, or into another grid in the same `dragGroup`.
///
/// ```swift
/// @State var apps: [URL] = …
/// @State var selection: Set<URL> = []
/// RiftGrid(items: $apps, selection: $selection, metrics: RiftGridMetrics(columns: .fixed(4))) {
///     cell in
///     AppIcon(url: cell.id).opacity(cell.isHovered ? 1 : 0.9)
/// }
/// ```
///
/// Reordering, and items arriving from or leaving for another grid, are written back to `items`.
public struct RiftGrid<ID: Hashable, Content: View>: NSViewRepresentable {
	@Binding private var items: [ID]
	private let selection: Binding<Set<ID>>?
	@Environment(\.riftThemeSelection) private var environmentTheme
	private let metrics: RiftGridMetrics
	private let dragGroup: String?
	private let allowsReordering: Bool
	private let allowsMultipleSelection: Bool
	private let acceptsItems: Bool
	private let drawsSelection: Bool
	private let forwardsClicksToContent: Bool
	private let theme: RiftThemeSelection?
	private let label: ((ID) -> String)?
	private let onOpen: (([ID]) -> Void)?
	private let canDropOnto: (([ID], ID) -> Bool)?
	private let onDropOnto: (([ID], ID) -> Bool)?
	private let onInsert: (([ID], Int) -> Bool)?
	private let onDragOut: (([ID], CGPoint) -> Void)?
	private let menu: ((Set<ID>) -> [RiftMenuItem])?
	private let content: (RiftGridCell<ID>) -> Content

	/// - Parameters:
	///   - items: the items in order; reordering and moves between grids are written back.
	///   - selection: the selected items (`nil`: the grid keeps its own selection).
	///   - metrics: cell size, spacing, insets, and whether the columns follow the width
	///     (`.fitting`) or are a fixed number.
	///   - dragGroup: grids with the same group take each other's items (`nil`: none do).
	///   - acceptsItems: take items dragged in from other grids in the group.
	///   - forwardsClicksToContent: also pass a plain click on to the cell's content (for cells
	///     with their own buttons). Selecting and dragging work either way.
	///   - label: a name for each item, for accessibility.
	///   - onOpen: a double-click or Return, with the selected items in order.
	///   - canDropOnto, onDropOnto: dropping items onto an item (a folder, say). Return `true`
	///     from `onDropOnto` when the items were taken; they are then removed from their grid.
	///   - onInsert: decide whether to take items from another grid at an index (the default
	///     takes them when `acceptsItems` is on).
	///   - onDragOut: items were dropped outside every grid, at this screen point.
	///   - menu: the menu for a right-click on the selection (or on nothing: an empty set).
	public init(
		items: Binding<[ID]>, selection: Binding<Set<ID>>? = nil,
		metrics: RiftGridMetrics = RiftGridMetrics(), dragGroup: String? = "rift.grid",
		allowsReordering: Bool = true, allowsMultipleSelection: Bool = true,
		acceptsItems: Bool = true, drawsSelection: Bool = true,
		forwardsClicksToContent: Bool = false, theme: RiftThemeSelection? = nil,
		label: ((ID) -> String)? = nil, onOpen: (([ID]) -> Void)? = nil,
		canDropOnto: (([ID], ID) -> Bool)? = nil, onDropOnto: (([ID], ID) -> Bool)? = nil,
		onInsert: (([ID], Int) -> Bool)? = nil, onDragOut: (([ID], CGPoint) -> Void)? = nil,
		menu: ((Set<ID>) -> [RiftMenuItem])? = nil,
		@ViewBuilder content: @escaping (RiftGridCell<ID>) -> Content
	) {
		_items = items
		self.selection = selection
		self.metrics = metrics
		self.dragGroup = dragGroup
		self.allowsReordering = allowsReordering
		self.allowsMultipleSelection = allowsMultipleSelection
		self.acceptsItems = acceptsItems
		self.drawsSelection = drawsSelection
		self.forwardsClicksToContent = forwardsClicksToContent
		self.theme = theme
		self.label = label
		self.onOpen = onOpen
		self.canDropOnto = canDropOnto
		self.onDropOnto = onDropOnto
		self.onInsert = onInsert
		self.onDragOut = onDragOut
		self.menu = menu
		self.content = content
	}

	public final class Coordinator {
		var parent: RiftGrid
		weak var grid: RiftGridView<ID>?
		init(_ parent: RiftGrid) { self.parent = parent }
	}

	public func makeCoordinator() -> Coordinator { Coordinator(self) }

	public func makeNSView(context: Context) -> NSScrollView {
		let coordinator = context.coordinator
		let grid = RiftGridView<ID> { id in
			let cell = RiftGridCell(id: id)
			let root = AnyView(RiftGridCellRoot(cell: cell) { coordinator.parent.content($0) })
			return RiftGridHostedCell(cell: cell, root: root)
		}
		coordinator.grid = grid
		grid.onSelectionChange = { coordinator.parent.selection?.wrappedValue = $0 }
		grid.onOpen = { coordinator.parent.onOpen?($0) }
		grid.onMove = { ids, index in
			let moved = RiftGridMath.moving(Set(ids), in: coordinator.parent.items, to: index)
			if moved != coordinator.parent.items { coordinator.parent.items = moved }
		}
		grid.onRemove = { ids in
			let gone = Set(ids)
			coordinator.parent.items.removeAll { gone.contains($0) }
		}
		grid.onInsert = { ids, index in
			let parent = coordinator.parent
			guard parent.onInsert?(ids, index) ?? parent.acceptsItems else { return false }
			var updated = parent.items.filter { !ids.contains($0) }
			updated.insert(contentsOf: ids, at: min(max(index, 0), updated.count))
			parent.items = updated
			return true
		}
		apply(to: grid, coordinator: coordinator)
		return grid.makeScrollView()
	}

	public func updateNSView(_ scroll: NSScrollView, context: Context) {
		let coordinator = context.coordinator
		coordinator.parent = self
		guard let grid = coordinator.grid else { return }
		apply(to: grid, coordinator: coordinator)
		for case let cell as RiftGridHostedCell<ID> in grid.itemViews { cell.refresh() }
	}

	private func apply(to grid: RiftGridView<ID>, coordinator: Coordinator) {
		grid.metrics = metrics
		grid.dragGroup = dragGroup
		grid.allowsReordering = allowsReordering
		grid.allowsMultipleSelection = allowsMultipleSelection
		if grid.drawsSelection != drawsSelection { grid.drawsSelection = drawsSelection }
		grid.forwardsClicksToContent = forwardsClicksToContent
		grid.theme = theme ?? environmentTheme
		grid.itemLabel = label.map { _ in { coordinator.parent.label?($0) ?? "" } }
		grid.canDropOnto = canDropOnto.map { _ in
			{ coordinator.parent.canDropOnto?($0, $1) ?? false }
		}
		grid.onDropOnto = onDropOnto.map { _ in
			{ coordinator.parent.onDropOnto?($0, $1) ?? false }
		}
		grid.onDragOut = onDragOut.map { _ in { coordinator.parent.onDragOut?($0, $1) } }
		grid.menuProvider = menu.map { _ in
			{ RiftMenuItem.menu(coordinator.parent.menu?($0) ?? []) }
		}
		grid.items = items
		if let selection, grid.selection != selection.wrappedValue {
			grid.selection = selection.wrappedValue
		}
	}

	/// Fills the space it is offered.
	public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context)
		-> CGSize?
	{
		guard let width = proposal.width, let height = proposal.height else { return nil }
		return CGSize(width: width, height: height)
	}
}
