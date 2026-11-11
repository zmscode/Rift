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
	/// How the pane is being presented: whether the layout has settled, zoom, sizes.
	public let presentation: RiftPanePresentation
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
	}

	@available(*, unavailable)
	required init(rootView: AnyView) { fatalError() }

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func riftPanePresentationDidChange(_ presentation: RiftPanePresentation) {
		let old = model.context
		model.context = RiftPaneContext(
			paneID: old.paneID, isFocused: old.isFocused,
			accessibilityLabel: old.accessibilityLabel,
			presentation: presentation)
	}

	func setTheme(_ selection: RiftThemeSelection?) {
		if model.themeSelection != selection { model.themeSelection = selection }
	}

	func setFocused(_ focused: Bool, label: String) {
		let old = model.context
		guard old.isFocused != focused || old.accessibilityLabel != label else { return }
		model.context = RiftPaneContext(
			paneID: old.paneID, isFocused: focused, accessibilityLabel: label,
			presentation: old.presentation)
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
	fileprivate let configuration: RiftConfiguration
	private let controller: RiftController<PaneID>?
	private let title: ((PaneID) -> String)?
	private let onLayoutSettled: (() -> Void)?
	private let onDividerDragChanged: ((Bool) -> Void)?
	private let onStructuralActivityChange: ((RiftStructuralActivity) -> Void)?
	private let onTearOut: ((PaneID, CGPoint) -> Void)?
	private let dragPreview: ((PaneID) -> AnyView)?
	private let paneActivity: ((PaneID) -> String?)?
	private let content: (RiftPaneContext<PaneID>) -> Content

	/// - Parameters:
	///   - layout: the panes. Rift writes back every change it makes (drags, drops, closes).
	///   - focusedPane: the focused pane, read and written.
	///   - zoomedPane: the zoomed pane, if the host wants to read or set it.
	///   - onTearOut: a pane dropped outside every window. It has already been removed; open it
	///     somewhere else (for example a new window with its own `RiftLayoutView`).
	///   - dragPreview: the view floating under the pointer while a pane is dragged, sized to fit.
	///     Without one, a snapshot of the pane is shown.
	///   - paneActivity: what a busy pane is doing ("is still working"); closing busy panes asks
	///     first.
	///   - content: the pane's SwiftUI content.
	public init(
		layout: Binding<RiftLayout<PaneID>?>,
		focusedPane: Binding<PaneID?> = .constant(nil),
		zoomedPane: Binding<PaneID?>? = nil,
		configuration: RiftConfiguration = RiftConfiguration(),
		controller: RiftController<PaneID>? = nil,
		title: ((PaneID) -> String)? = nil,
		onLayoutSettled: (() -> Void)? = nil,
		onDividerDragChanged: ((Bool) -> Void)? = nil,
		onStructuralActivityChange: ((RiftStructuralActivity) -> Void)? = nil,
		onTearOut: ((PaneID, CGPoint) -> Void)? = nil,
		dragPreview: ((PaneID) -> AnyView)? = nil,
		paneActivity: ((PaneID) -> String?)? = nil,
		@ViewBuilder content: @escaping (RiftPaneContext<PaneID>) -> Content
	) {
		_layout = layout
		_focusedPane = focusedPane
		self.zoomedPane = zoomedPane
		self.configuration = configuration
		self.controller = controller
		self.title = title
		self.onLayoutSettled = onLayoutSettled
		self.onDividerDragChanged = onDividerDragChanged
		self.onStructuralActivityChange = onStructuralActivityChange
		self.onTearOut = onTearOut
		self.dragPreview = dragPreview
		self.paneActivity = paneActivity
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
					presentation: RiftPanePresentation(
						isLayoutSettled: true, zoomFraction: 0, contentSize: .zero, targetSize: nil)
				))
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
		view.onLayoutSettled = { coordinator.parent.onLayoutSettled?() }
		view.onDividerDragChanged = { coordinator.parent.onDividerDragChanged?($0) }
		view.onStructuralActivityChange = { coordinator.parent.onStructuralActivityChange?($0) }
		view.onTearOut = { pane, _, point in coordinator.parent.onTearOut?(pane, point) }
		view.paneActivity = { pane in coordinator.parent.paneActivity?(pane) }
		view.makeDragPreview = { pane in
			coordinator.parent.dragPreview.map { NSHostingView(rootView: $0(pane)) }
		}
		controller?.view = view
		Self.syncFocus(in: view, coordinator: coordinator)
		return view
	}

	public func updateNSView(_ view: RiftView<PaneID>, context: Context) {
		context.coordinator.parent = self
		view.configuration = configuration
		view.paneTitle = title
		controller?.view = view
		if view.paneLayout != layout { view.setLayout(layout, animated: true) }
		if let focusedPane, view.focusedPane != focusedPane { view.focusedPane = focusedPane }
		if let zoomedPane, view.zoomedPane != zoomedPane.wrappedValue {
			view.setZoom(zoomedPane.wrappedValue)
		}
		Self.syncFocus(in: view, coordinator: context.coordinator)
	}

	/// Keeps every pane's `isFocused` and label current.
	@MainActor
	private static func syncFocus(in view: RiftView<PaneID>, coordinator: Coordinator) {
		for id in view.paneLayout?.paneIDs ?? [] {
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

/// A sidebar beside your content, for SwiftUI (see `RiftSidebarContainerView`). Put a
/// `RiftLayoutView` in the content and its pane headers keep room for the window buttons and the
/// sidebar's toggle as the sidebar folds.
///
/// ```swift
/// @State var collapsed = false
/// @State var width: CGFloat = 240
/// RiftSidebarSplitView(isCollapsed: $collapsed, width: $width) {
///     MySidebar()
/// } content: {
///     RiftLayoutView(layout: $layout) { pane in MyPane(pane) }
/// }
/// ```
public struct RiftSidebarSplitView<Sidebar: View, Content: View>: NSViewRepresentable {
	@Binding private var isCollapsed: Bool
	@Binding private var width: CGFloat
	private let position: RiftSidebarPosition
	private let density: RiftChromeDensity
	private let preservesWindowWidth: Bool
	private let swipe: RiftSidebarSwipe
	private let animationStyle: RiftAnimationStyle
	private let hidesToggleButton: Bool
	private let onCollapseProgressChange: ((CGFloat) -> Void)?
	private let onPositionChange: ((RiftSidebarPosition) -> Void)?
	private let onDensityChange: ((RiftChromeDensity) -> Void)?
	private let accessories: [RiftSidebarAccessory]
	private let toggleShortcut: String?
	private let theme: RiftThemeSelection?
	private let sidebar: Sidebar
	private let content: Content

	/// - Parameters:
	///   - isCollapsed: whether the sidebar is folded away; written when the user folds it.
	///   - width: the sidebar's open width; written when the user resizes it.
	///   - preservesWindowWidth: keep the window's width when folding (the content takes the
	///     space) instead of shrinking and growing the window.
	///   - animationStyle: the fold uses this style's chrome curve.
	///   - accessories: the sidebar's own buttons, in its title row beside the toggle; the ones
	///     that don't fit go into a "more" menu.
	///   - onPositionChange, onDensityChange: the user picked a side or density from the toggle
	///     button's right-click menu. Give either to show the menu.
	public init(
		isCollapsed: Binding<Bool>,
		width: Binding<CGFloat> = .constant(RiftSidebarMath.defaultWidth),
		position: RiftSidebarPosition = .left,
		density: RiftChromeDensity = .comfortable,
		preservesWindowWidth: Bool = true,
		swipe: RiftSidebarSwipe = .swipe,
		animationStyle: RiftAnimationStyle = .snappy,
		hidesToggleButton: Bool = false,
		onCollapseProgressChange: ((CGFloat) -> Void)? = nil,
		onPositionChange: ((RiftSidebarPosition) -> Void)? = nil,
		onDensityChange: ((RiftChromeDensity) -> Void)? = nil,
		accessories: [RiftSidebarAccessory] = [],
		toggleShortcut: String? = nil,
		theme: RiftThemeSelection? = nil,
		@ViewBuilder sidebar: () -> Sidebar,
		@ViewBuilder content: () -> Content
	) {
		_isCollapsed = isCollapsed
		_width = width
		self.position = position
		self.density = density
		self.preservesWindowWidth = preservesWindowWidth
		self.swipe = swipe
		self.animationStyle = animationStyle
		self.hidesToggleButton = hidesToggleButton
		self.onCollapseProgressChange = onCollapseProgressChange
		self.onPositionChange = onPositionChange
		self.onDensityChange = onDensityChange
		self.accessories = accessories
		self.toggleShortcut = toggleShortcut
		self.theme = theme
		self.sidebar = sidebar()
		self.content = content()
	}

	public final class Coordinator {
		var parent: RiftSidebarSplitView
		let sidebarHost: NSHostingView<AnyView>
		let contentHost: NSHostingView<AnyView>
		init(_ parent: RiftSidebarSplitView) {
			self.parent = parent
			sidebarHost = NSHostingView(rootView: parent.sidebarRoot)
			contentHost = NSHostingView(rootView: AnyView(parent.content.ignoresSafeArea()))
			sidebarHost.sizingOptions = []
			contentHost.sizingOptions = []
		}
	}

	public func makeCoordinator() -> Coordinator { Coordinator(self) }

	public func makeNSView(context: Context) -> RiftSidebarContainerView {
		let coordinator = context.coordinator
		let view = RiftSidebarContainerView(
			sidebar: coordinator.sidebarHost, content: coordinator.contentHost)
		view.width = width
		if isCollapsed { view.setCollapsed(true, animated: false) }
		view.onCollapsedChange = { coordinator.parent.isCollapsed = $0 }
		view.onWidthChange = { coordinator.parent.width = $0 }
		view.onCollapseProgressChange = { coordinator.parent.onCollapseProgressChange?($0) }
		apply(to: view)
		return view
	}

	public func updateNSView(_ view: RiftSidebarContainerView, context: Context) {
		context.coordinator.parent = self
		context.coordinator.sidebarHost.rootView = sidebarRoot
		context.coordinator.contentHost.rootView = AnyView(content.ignoresSafeArea())
		apply(to: view)
		if view.width != width { view.width = width }
		if view.isCollapsed != isCollapsed { view.setCollapsed(isCollapsed, animated: true) }
		view.refreshChrome()
	}

	/// The sidebar content, told how tall the title row is.
	var sidebarRoot: AnyView {
		AnyView(
			sidebar
				.environment(\.riftSidebarTitleRowHeight, RiftSidebarMath.titleRowHeight(density: density))
				.environment(\.riftThemeSelection, theme)
				.ignoresSafeArea())
	}

	private func apply(to view: RiftSidebarContainerView) {
		view.accessories = accessories
		if view.toggleShortcut != toggleShortcut { view.toggleShortcut = toggleShortcut }
		if view.theme != theme { view.theme = theme }
		if view.position != position { view.position = position }
		if view.density != density { view.density = density }
		view.preservesWindowWidth = preservesWindowWidth
		view.swipe = swipe
		view.foldCurve = animationStyle.chromeCurve
		view.onPositionChange = onPositionChange
		view.onDensityChange = onDensityChange
		if view.hidesToggleButton != hidesToggleButton {
			view.hidesToggleButton = hidesToggleButton
		}
	}
}

private struct RiftSidebarTitleRowHeightKey: EnvironmentKey {
	static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
	/// Inside a `RiftSidebarSplitView` sidebar: the height of its title row (the toggle and the
	/// sidebar's buttons sit in it, and it drags the window). Start your content below it.
	public var riftSidebarTitleRowHeight: CGFloat {
		get { self[RiftSidebarTitleRowHeightKey.self] }
		set { self[RiftSidebarTitleRowHeightKey.self] = newValue }
	}
}
