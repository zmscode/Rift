import AppKit
import Observation
import RiftCore
import SwiftUI

/// Sends commands (split, close, focus, …) to the layout behind a `RiftLayoutView`.
@MainActor
public final class RiftController<PaneID: Hashable & Sendable> {
	public internal(set) weak var view: RiftView<PaneID>?

	public init() {}

	@discardableResult
	public func split(_ pane: PaneID? = nil, edge: RiftEdge, newPane: PaneID) -> Bool {
		view?.split(pane, edge: edge, newPane: newPane) ?? false
	}
	@discardableResult
	public func splitAll(edge: RiftEdge, newPane: PaneID) -> Bool {
		view?.splitAll(edge: edge, newPane: newPane) ?? false
	}
	@discardableResult
	public func close(_ pane: PaneID? = nil) -> Bool { view?.close(pane) ?? false }
	@discardableResult
	public func closeOthers(_ pane: PaneID? = nil) -> Bool { view?.closeOthers(pane) ?? false }

	/// Lifts a pane into a floating layer, or docks a floating one back into the layout.
	@discardableResult
	public func toggleFloating(_ pane: PaneID? = nil) -> Bool {
		view?.toggleFloating(pane) ?? false
	}

	@discardableResult
	public func float(_ pane: PaneID? = nil) -> Bool { view?.float(pane) ?? false }

	@discardableResult
	public func dock(_ pane: PaneID) -> Bool { view?.dock(pane) ?? false }

	/// Minimises a floating layer to a capsule, or brings it back.
	public func setMinimised(_ minimised: Bool, layer: UUID) {
		view?.setMinimised(minimised, layer: layer)
	}
	@discardableResult
	public func moveFocus(_ direction: RiftDirection, wraps: Bool = true) -> Bool {
		view?.moveFocus(direction, wraps: wraps) ?? false
	}
	@discardableResult
	public func resize(toward direction: RiftDirection, by points: CGFloat? = nil) -> Bool {
		view?.resize(toward: direction, by: points) ?? false
	}
	@discardableResult
	public func swap(toward direction: RiftDirection) -> Bool {
		view?.swap(toward: direction) ?? false
	}
	public func balance() { view?.balance() }
	public func toggleZoom() { view?.toggleZoom() }

	/// Announces that the layout is about to animate to `width` (see `RiftContainerAnimation`).
	public func beginContainerAnimation(toWidth width: CGFloat) {
		view?.beginContainerAnimation(toWidth: width)
	}
	public func endContainerAnimation() { view?.endContainerAnimation() }

	/// What is reshaping the panes right now.
	public var structuralActivity: RiftStructuralActivity { view?.structuralActivity ?? [] }
}

/// What a pane's SwiftUI content gets to build itself.
public struct RiftPaneContext<PaneID: Hashable & Sendable> {
	public let paneID: PaneID
	public let isFocused: Bool
	public let accessibilityLabel: String
	/// How the pane is being presented: whether the layout has settled, zoom, sizes. Each value is
	/// observed on its own, so content is only rebuilt for the values it reads: a pane that reads
	/// `isLayoutSettled` is not rebuilt on every frame of a resize, one that reads `contentSize` is.
	public let presentation: RiftPanePresentationState
	/// Whether the pointer is over the pane (and not over a floating layer above it).
	public var isHovered: Bool = false
}

/// A pane's presentation for SwiftUI content: the values of `RiftPanePresentation`, each observed
/// separately. One object lives as long as its pane, and its values change in place.
@MainActor
@Observable
public final class RiftPanePresentationState {
	/// `false` while the layout is moving.
	public private(set) var isLayoutSettled = true
	/// 0 tiled, 1 filling the layout, in between while the zoom animates.
	public private(set) var zoomFraction: CGFloat = 0
	/// The content's current size.
	public private(set) var contentSize: CGSize = .zero
	/// While the layout moves, the size the content will end at.
	public private(set) var targetSize: CGSize?
	/// The content's width when it differs from its pane's.
	public private(set) var contentWidth: CGFloat?
	/// How much of the content is cut off past the pane's trailing edge.
	public private(set) var hiddenTrailingWidth: CGFloat = 0
	/// The size of the pane's surface.
	public private(set) var surfaceSize: CGSize?
	/// Room to keep clear at the start and end of a title row along the pane's top edge.
	public private(set) var titleLeadingInset: CGFloat = 0
	public private(set) var titleTrailingInset: CGFloat = 0
	/// The height of a title row that lines up with the window buttons (`nil` away from them).
	public private(set) var titleRowHeight: CGFloat?

	/// Every value at once (reading this observes all of them).
	public var snapshot: RiftPanePresentation {
		var value = RiftPanePresentation(
			isLayoutSettled: isLayoutSettled, zoomFraction: zoomFraction, contentSize: contentSize,
			targetSize: targetSize, contentWidth: contentWidth,
			hiddenTrailingWidth: hiddenTrailingWidth, surfaceSize: surfaceSize)
		value.titleLeadingInset = titleLeadingInset
		value.titleTrailingInset = titleTrailingInset
		value.titleRowHeight = titleRowHeight
		return value
	}

	/// Takes new values, touching only the ones that changed (a write notifies observers even
	/// when the value is the same).
	func apply(_ value: RiftPanePresentation) {
		if isLayoutSettled != value.isLayoutSettled { isLayoutSettled = value.isLayoutSettled }
		if zoomFraction != value.zoomFraction { zoomFraction = value.zoomFraction }
		if contentSize != value.contentSize { contentSize = value.contentSize }
		if targetSize != value.targetSize { targetSize = value.targetSize }
		if contentWidth != value.contentWidth { contentWidth = value.contentWidth }
		if hiddenTrailingWidth != value.hiddenTrailingWidth {
			hiddenTrailingWidth = value.hiddenTrailingWidth
		}
		if surfaceSize != value.surfaceSize { surfaceSize = value.surfaceSize }
		if titleLeadingInset != value.titleLeadingInset {
			titleLeadingInset = value.titleLeadingInset
		}
		if titleTrailingInset != value.titleTrailingInset {
			titleTrailingInset = value.titleTrailingInset
		}
		if titleRowHeight != value.titleRowHeight { titleRowHeight = value.titleRowHeight }
	}
}

/// An item in a pane's menu (see `RiftLayoutView`'s `paneMenu`).
public struct RiftMenuItem {
	public var title: String
	public var systemImage: String?
	public var isEnabled: Bool
	public var action: (() -> Void)?

	public init(
		_ title: String, systemImage: String? = nil, isEnabled: Bool = true,
		action: @escaping () -> Void
	) {
		self.title = title
		self.systemImage = systemImage
		self.isEnabled = isEnabled
		self.action = action
	}

	private init() {
		title = ""
		systemImage = nil
		isEnabled = false
		action = nil
	}

	/// A line between groups of items.
	public static var separator: RiftMenuItem { RiftMenuItem() }

	@MainActor static func menu(_ items: [RiftMenuItem]) -> NSMenu? {
		guard !items.isEmpty else { return nil }
		let menu = NSMenu()
		menu.autoenablesItems = false
		for item in items {
			guard let action = item.action else {
				menu.addItem(.separator())
				continue
			}
			let entry = RiftClosureMenuItem(title: item.title, handler: action)
			entry.isEnabled = item.isEnabled
			if let image = item.systemImage {
				entry.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
			}
			menu.addItem(entry)
		}
		return menu
	}
}

/// Holds one pane's context so its SwiftUI content updates when focus or presentation changes.
@MainActor
@Observable
final class RiftPaneModel<PaneID: Hashable & Sendable> {
	var context: RiftPaneContext<PaneID>
	/// The theme pane content reads from the environment.
	var themeSelection: RiftThemeSelection?
	init(_ context: RiftPaneContext<PaneID>) { self.context = context }
}

/// Renders a pane's content from its model.
struct RiftPaneRoot<PaneID: Hashable & Sendable, Content: View>: View {
	let model: RiftPaneModel<PaneID>
	let content: (RiftPaneContext<PaneID>) -> Content
	// Rift sets each pane's insets itself, so the window's safe area (the titlebar) must not
	// push pane content down.
	var body: some View {
		content(model.context)
			.environment(\.riftThemeSelection, model.themeSelection)
			.ignoresSafeArea()
	}
}

/// Hosts a pane's SwiftUI content inside the native layout and forwards presentation changes.
@MainActor
final class RiftHostedPane<PaneID: Hashable & Sendable>: NSHostingView<AnyView>,
	RiftPanePresentationObserving
{
	let model: RiftPaneModel<PaneID>

	init(model: RiftPaneModel<PaneID>, root: AnyView) {
		self.model = model
		super.init(rootView: root)
		// The layout sizes the pane; the content never sizes the hosting view. With the default
		// options every resize re-measures the content's minimum, ideal and maximum sizes.
		sizingOptions = []
	}

	@available(*, unavailable)
	required init(rootView: AnyView) { fatalError() }

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func riftPanePresentationDidChange(_ presentation: RiftPanePresentation) {
		// The context keeps the same presentation object, so only content that reads a changed
		// value is rebuilt.
		model.context.presentation.apply(presentation)
	}

	func setHovered(_ hovered: Bool) {
		guard model.context.isHovered != hovered else { return }
		model.context.isHovered = hovered
	}

	func setTheme(_ selection: RiftThemeSelection?) {
		if model.themeSelection != selection { model.themeSelection = selection }
	}

	func setFocused(_ focused: Bool, label: String) {
		let old = model.context
		guard old.isFocused != focused || old.accessibilityLabel != label else { return }
		model.context = RiftPaneContext(
			paneID: old.paneID, isFocused: focused, accessibilityLabel: label,
			presentation: old.presentation, isHovered: old.isHovered)
	}
}

/// A split layout for SwiftUI. The host owns the layout, focus and zoom through bindings; each
/// pane's content is a SwiftUI view built from a `RiftPaneContext`. A native `RiftView` does the
/// layout, motion, dividers and drag and drop underneath.
///
/// ```swift
/// @State var layout: RiftLayout<String>? = .pane("a")
/// @State var focused: String?
/// RiftLayoutView(layout: $layout, focusedPane: $focused) { pane in
///     Text(pane.paneID).opacity(pane.presentation.isLayoutSettled ? 1 : 0.8)
/// }
/// ```
public struct RiftLayoutView<PaneID: Hashable & Sendable, Content: View>: NSViewRepresentable {
	@Binding private var layout: RiftLayout<PaneID>?
	@Binding private var focusedPane: PaneID?
	private let zoomedPane: Binding<PaneID?>?
	private let floating: Binding<[RiftFloatingLayer<PaneID>]>?
	fileprivate let configuration: RiftConfiguration
	private let controller: RiftController<PaneID>?
	private let title: ((PaneID) -> String)?
	private let onLayoutSettled: (() -> Void)?
	private let onDividerDragChanged: ((Bool) -> Void)?
	private let onStructuralActivityChange: ((RiftStructuralActivity) -> Void)?
	private let onTearOut: ((PaneID, CGPoint) -> Void)?
	private let dragPreview: ((PaneID) -> AnyView)?
	private let paneActivity: ((PaneID) -> String?)?
	private let paneActions: ((PaneID) -> [RiftPaneHeaderAction])?
	private let paneMenu: ((PaneID) -> [RiftMenuItem])?
	private let onRenamePane: ((PaneID, String) -> Void)?
	private let content: (RiftPaneContext<PaneID>) -> Content
	private var isLayoutHidden = false

	/// - Parameters:
	///   - layout: the panes. Rift writes back every change it makes (drags, drops, closes).
	///   - focusedPane: the focused pane, read and written.
	///   - zoomedPane: the zoomed pane, if the host wants to read or set it.
	///   - floating: floating layers above the layout (see `RiftFloatingLayer`), read and written.
	///   - onTearOut: a pane dropped outside every window. It has already been removed; open it
	///     somewhere else (for example a new window with its own `RiftLayoutView`).
	///   - dragPreview: the view floating under the pointer while a pane is dragged, sized to fit.
	///     Without one, a snapshot of the pane is shown.
	///   - paneActivity: what a busy pane is doing ("is still working"); closing busy panes asks
	///     first.
	///   - paneActions: buttons at the trailing edge of pane headers (with `showsPaneHeaders`).
	///   - paneMenu: the menu for a right-click in a pane's header or top strip.
	///   - onRenamePane: lets the focused pane's header title be clicked to rename it.
	///   - content: the pane's SwiftUI content.
	public init(
		layout: Binding<RiftLayout<PaneID>?>,
		focusedPane: Binding<PaneID?> = .constant(nil),
		zoomedPane: Binding<PaneID?>? = nil,
		floating: Binding<[RiftFloatingLayer<PaneID>]>? = nil,
		configuration: RiftConfiguration = RiftConfiguration(),
		controller: RiftController<PaneID>? = nil,
		title: ((PaneID) -> String)? = nil,
		onLayoutSettled: (() -> Void)? = nil,
		onDividerDragChanged: ((Bool) -> Void)? = nil,
		onStructuralActivityChange: ((RiftStructuralActivity) -> Void)? = nil,
		onTearOut: ((PaneID, CGPoint) -> Void)? = nil,
		dragPreview: ((PaneID) -> AnyView)? = nil,
		paneActivity: ((PaneID) -> String?)? = nil,
		paneActions: ((PaneID) -> [RiftPaneHeaderAction])? = nil,
		paneMenu: ((PaneID) -> [RiftMenuItem])? = nil,
		onRenamePane: ((PaneID, String) -> Void)? = nil,
		@ViewBuilder content: @escaping (RiftPaneContext<PaneID>) -> Content
	) {
		_layout = layout
		_focusedPane = focusedPane
		self.zoomedPane = zoomedPane
		self.floating = floating
		self.configuration = configuration
		self.controller = controller
		self.title = title
		self.onLayoutSettled = onLayoutSettled
		self.onDividerDragChanged = onDividerDragChanged
		self.onStructuralActivityChange = onStructuralActivityChange
		self.onTearOut = onTearOut
		self.dragPreview = dragPreview
		self.paneActivity = paneActivity
		self.paneActions = paneActions
		self.paneMenu = paneMenu
		self.onRenamePane = onRenamePane
		self.content = content
	}

	public final class Coordinator {
		var parent: RiftLayoutView
		init(_ parent: RiftLayoutView) { self.parent = parent }
	}

	public func makeCoordinator() -> Coordinator { Coordinator(self) }

	public func makeNSView(context: Context) -> RiftView<PaneID> {
		let coordinator = context.coordinator
		let view = RiftView<PaneID>(configuration: configuration) { id in
			let label = coordinator.parent.title?(id) ?? String(describing: id)
			let model = RiftPaneModel(
				RiftPaneContext(
					paneID: id, isFocused: false, accessibilityLabel: label,
					presentation: RiftPanePresentationState()))
			let root = AnyView(RiftPaneRoot(model: model) { coordinator.parent.content($0) })
			return RiftHostedPane(model: model, root: root)
		}
		view.paneTitle = title
		view.setLayout(layout)
		view.focusedPane = focusedPane ?? layout?.firstPaneID
		view.onLayoutChange = { [weak view] layout, _ in
			coordinator.parent.layout = layout
			if let view { Self.syncFocus(in: view, coordinator: coordinator) }
		}
		view.onFocusChange = { [weak view] pane in
			coordinator.parent.focusedPane = pane
			if let view { Self.syncFocus(in: view, coordinator: coordinator) }
		}
		view.onZoomChange = { pane in coordinator.parent.zoomedPane?.wrappedValue = pane }
		view.onFloatingLayersChange = { [weak view] layers in
			coordinator.parent.floating?.wrappedValue = layers
			if let view { Self.syncFocus(in: view, coordinator: coordinator) }
		}
		if let floating { view.setFloatingLayers(floating.wrappedValue) }
		view.onLayoutSettled = { coordinator.parent.onLayoutSettled?() }
		view.onDividerDragChanged = { coordinator.parent.onDividerDragChanged?($0) }
		view.onStructuralActivityChange = { coordinator.parent.onStructuralActivityChange?($0) }
		view.onTearOut = { pane, _, point in coordinator.parent.onTearOut?(pane, point) }
		view.paneActivity = { pane in coordinator.parent.paneActivity?(pane) }
		view.onHoverChange = { [weak view] pane in
			guard let view else { return }
			for id in view.allPaneIDs {
				(view.contentView(for: id) as? RiftHostedPane<PaneID>)?.setHovered(id == pane)
			}
		}
		view.makeDragPreview = { pane in
			coordinator.parent.dragPreview.map { NSHostingView(rootView: $0(pane)) }
		}
		controller?.view = view
		Self.syncFocus(in: view, coordinator: coordinator)
		return view
	}

	/// Hides the layout but keeps it (and its panes) alive, as for a tab in the background. A
	/// hidden layout takes no drops, and a pane dragged out of it can still land elsewhere.
	public func layoutHidden(_ hidden: Bool = true) -> Self {
		var copy = self
		copy.isLayoutHidden = hidden
		return copy
	}

	public func updateNSView(_ view: RiftView<PaneID>, context: Context) {
		context.coordinator.parent = self
		let coordinator = context.coordinator
		view.paneActions = paneActions.map { _ in { coordinator.parent.paneActions?($0) ?? [] } }
		view.paneMenu = paneMenu.map { _ in
			{ RiftMenuItem.menu(coordinator.parent.paneMenu?($0) ?? []) }
		}
		view.onRenamePane = onRenamePane.map { _ in { coordinator.parent.onRenamePane?($0, $1) } }
		if view.isHidden != isLayoutHidden { view.isHidden = isLayoutHidden }
		view.configuration = configuration
		view.paneTitle = title
		controller?.view = view
		if view.paneLayout != layout { view.setLayout(layout, animated: true) }
		if let floating, view.floatingLayers != floating.wrappedValue {
			view.setFloatingLayers(floating.wrappedValue)
		}
		if let focusedPane, view.focusedPane != focusedPane { view.focusedPane = focusedPane }
		if let zoomedPane, view.zoomedPane != zoomedPane.wrappedValue {
			view.setZoom(zoomedPane.wrappedValue)
		}
		Self.syncFocus(in: view, coordinator: context.coordinator)
	}

	/// A layout fills the space it is offered. Without this, SwiftUI measures the whole view tree
	/// through Auto Layout on every resize.
	public func sizeThatFits(
		_ proposal: ProposedViewSize, nsView: RiftView<PaneID>, context: Context
	) -> CGSize? {
		guard let width = proposal.width, let height = proposal.height else { return nil }
		return CGSize(width: width, height: height)
	}

	/// Keeps every pane's `isFocused` and label current.
	@MainActor
	private static func syncFocus(in view: RiftView<PaneID>, coordinator: Coordinator) {
		for id in view.allPaneIDs {
			guard let pane = view.contentView(for: id) as? RiftHostedPane<PaneID> else { continue }
			let label = coordinator.parent.title?(id) ?? String(describing: id)
			pane.setFocused(view.focusedPane == id, label: label)
			pane.setTheme(coordinator.parent.configuration.theme)
		}
	}
}

extension RiftLayoutView {
	/// Builds each pane from its identifier only.
	public init(
		layout: Binding<RiftLayout<PaneID>?>,
		focusedPane: Binding<PaneID?> = .constant(nil),
		configuration: RiftConfiguration = RiftConfiguration(),
		controller: RiftController<PaneID>? = nil,
		title: ((PaneID) -> String)? = nil,
		@ViewBuilder paneContent: @escaping (PaneID) -> Content
	) {
		self.init(
			layout: layout, focusedPane: focusedPane, configuration: configuration,
			controller: controller, title: title
		) { paneContent($0.paneID) }
	}
}
