import AppKit
import Observation
import RiftCore
import SwiftUI

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
	private let footerAccessories: [RiftSidebarAccessory]
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
	///   - footerAccessories: round icon buttons in a 40pt footer row along the sidebar's bottom,
	///     from its trailing edge inward. The sidebar's content ends above the footer.
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
		footerAccessories: [RiftSidebarAccessory] = [],
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
		self.footerAccessories = footerAccessories
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
				.environment(
					\.riftSidebarTitleRowHeight, RiftSidebarMath.titleRowHeight(density: density)
				)
				.environment(\.riftThemeSelection, theme)
				.ignoresSafeArea())
	}

	/// Fills the space it is offered (see `RiftLayoutView.sizeThatFits`), but is never narrower
	/// than the window minimum: SwiftUI sets the window's minimum size from its content, so this
	/// is what stops the window being dragged narrower than the sidebar allows.
	public func sizeThatFits(
		_ proposal: ProposedViewSize, nsView: RiftSidebarContainerView, context: Context
	) -> CGSize? {
		guard let width = proposal.width, let height = proposal.height else { return nil }
		let minimum = nsView.managesWindowMinimumWidth ? nsView.windowMinimumWidth : 0
		return CGSize(width: max(width, minimum), height: height)
	}

	private func apply(to view: RiftSidebarContainerView) {
		view.accessories = accessories
		view.footerAccessories = footerAccessories
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
