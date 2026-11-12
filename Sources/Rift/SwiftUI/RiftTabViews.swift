import AppKit
import Observation
import RiftCore
import SwiftUI

/// A row of tabs, for SwiftUI (see `RiftTabBarView`). Moves, renames and closes are written back
/// to `tabs` (closing the selected tab selects the next one); pass the callbacks to do more.
///
/// ```swift
/// @State var tabs = [RiftTab(id: 1, title: "Notes")]
/// @State var selection: Int? = 1
/// RiftTabBar(tabs: $tabs, selection: $selection) {
///     tabs.append(RiftTab(id: tabs.count + 1, title: "Untitled"))
/// }
/// ```
public struct RiftTabBar<ID: Hashable>: NSViewRepresentable {
	@Binding private var tabs: [RiftTab<ID>]
	@Binding private var selection: ID?
	@Environment(\.riftThemeSelection) private var environmentTheme
	private let density: RiftChromeDensity
	private let fillsAvailableSpace: Bool
	private let leadingInset: CGFloat
	private let trailingInset: CGFloat
	private let theme: RiftThemeSelection?
	private let dragGroup: String
	private let onNewTab: (() -> Void)?
	private let onClose: ((ID) -> Void)?
	private let onTearOff: ((ID, CGPoint) -> Void)?
	private let onPaneDrop: ((AnyHashable, Int) -> Bool)?

	/// - Parameters:
	///   - leadingInset: room for the window buttons when the bar sits in the title bar.
	///   - dragGroup: panes dragged from Rift views with this `RiftView.groupIdentifier`
	///     can be dropped on the bar (the default matches theirs).
	///   - onNewTab: shows the new-tab button (and double-clicking the empty bar).
	///   - onClose: replaces the built-in close (removing the tab from `tabs`).
	///   - onTearOff: a tab dropped outside every window.
	///   - onPaneDrop: a pane dropped between tabs: make it a tab at the index, returning whether
	///     it was taken.
	public init(
		tabs: Binding<[RiftTab<ID>]>, selection: Binding<ID?>,
		density: RiftChromeDensity = .comfortable, fillsAvailableSpace: Bool = false,
		leadingInset: CGFloat = 0, trailingInset: CGFloat = 0, theme: RiftThemeSelection? = nil,
		dragGroup: String = "rift.default", onClose: ((ID) -> Void)? = nil,
		onTearOff: ((ID, CGPoint) -> Void)? = nil,
		onPaneDrop: ((AnyHashable, Int) -> Bool)? = nil, onNewTab: (() -> Void)? = nil
	) {
		_tabs = tabs
		_selection = selection
		self.density = density
		self.fillsAvailableSpace = fillsAvailableSpace
		self.leadingInset = leadingInset
		self.trailingInset = trailingInset
		self.theme = theme
		self.dragGroup = dragGroup
		self.onNewTab = onNewTab
		self.onClose = onClose
		self.onTearOff = onTearOff
		self.onPaneDrop = onPaneDrop
	}

	public final class Coordinator {
		var parent: RiftTabBar
		init(_ parent: RiftTabBar) { self.parent = parent }

		@MainActor func close(_ id: ID) {
			if let onClose = parent.onClose { return onClose(id) }
			var tabs = parent.tabs
			guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
			if parent.selection == id {
				parent.selection = RiftTabBarMath.selectionAfterClosing(
					index: index, count: tabs.count
				)
				.map { tabs[$0 < index ? $0 : $0 + 1].id }
			}
			tabs.remove(at: index)
			parent.tabs = tabs
		}
	}

	public func makeCoordinator() -> Coordinator { Coordinator(self) }

	public func makeNSView(context: Context) -> RiftTabBarView<ID> {
		let coordinator = context.coordinator
		let view = RiftTabBarView<ID>()
		view.onSelect = { coordinator.parent.selection = $0 }
		view.onClose = { coordinator.close($0) }
		view.onCloseOthers = { id in
			for tab in coordinator.parent.tabs where tab.id != id && tab.isClosable {
				coordinator.close(tab.id)
			}
			coordinator.parent.selection = id
		}
		view.onMove = { id, index in
			var tabs = coordinator.parent.tabs
			guard let from = tabs.firstIndex(where: { $0.id == id }), tabs.indices.contains(index)
			else { return }
			tabs.insert(tabs.remove(at: from), at: index)
			coordinator.parent.tabs = tabs
		}
		view.onRename = { id, title in
			guard let index = coordinator.parent.tabs.firstIndex(where: { $0.id == id }) else {
				return
			}
			coordinator.parent.tabs[index].title = title
		}
		updateNSView(view, context: context)
		return view
	}

	public func updateNSView(_ view: RiftTabBarView<ID>, context: Context) {
		let coordinator = context.coordinator
		coordinator.parent = self
		view.density = density
		view.surfaces = .modern(density)
		view.fillsAvailableSpace = fillsAvailableSpace
		view.leadingInset = leadingInset
		view.trailingInset = trailingInset
		view.theme = theme ?? environmentTheme
		view.paneDropGroup = dragGroup
		view.showsNewTabButton = onNewTab != nil
		view.onNewTab = onNewTab.map { _ in { coordinator.parent.onNewTab?() } }
		view.onTearOff = onTearOff.map { _ in { coordinator.parent.onTearOff?($0, $1) } }
		view.onPaneDrop = onPaneDrop.map { _ in { coordinator.parent.onPaneDrop?($0, $1) ?? false }
		}
		view.tabs = tabs
		view.selectedTab = selection
	}

	public func sizeThatFits(
		_ proposal: ProposedViewSize, nsView: RiftTabBarView<ID>, context: Context
	) -> CGSize? {
		CGSize(
			width: proposal.width ?? 400,
			height: RiftTabBarMath.buttonSize(density: density) + 4)
	}
}

/// Tabs as sidebar rows, for SwiftUI (see `RiftTabListView`). It is as tall as its rows. Moves,
/// renames and closes are written back to `tabs` (closing the selected tab selects the next one).
public struct RiftTabList<ID: Hashable>: NSViewRepresentable {
	@Binding private var tabs: [RiftTab<ID>]
	@Binding private var selection: ID?
	@Environment(\.riftThemeSelection) private var environmentTheme
	private let density: RiftChromeDensity
	private let textSize: RiftSidebarTextSize
	private let theme: RiftThemeSelection?
	private let dragGroup: String
	private let onClose: ((ID) -> Void)?
	private let onTearOff: ((ID, CGPoint) -> Void)?
	private let onPaneDrop: ((AnyHashable, Int) -> Bool)?

	public init(
		tabs: Binding<[RiftTab<ID>]>, selection: Binding<ID?>,
		density: RiftChromeDensity = .comfortable, textSize: RiftSidebarTextSize = .medium,
		theme: RiftThemeSelection? = nil, dragGroup: String = "rift.default",
		onClose: ((ID) -> Void)? = nil, onTearOff: ((ID, CGPoint) -> Void)? = nil,
		onPaneDrop: ((AnyHashable, Int) -> Bool)? = nil
	) {
		_tabs = tabs
		_selection = selection
		self.density = density
		self.textSize = textSize
		self.theme = theme
		self.dragGroup = dragGroup
		self.onClose = onClose
		self.onTearOff = onTearOff
		self.onPaneDrop = onPaneDrop
	}

	public final class Coordinator {
		var parent: RiftTabList
		init(_ parent: RiftTabList) { self.parent = parent }

		@MainActor func close(_ id: ID) {
			if let onClose = parent.onClose { return onClose(id) }
			var tabs = parent.tabs
			guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
			if parent.selection == id {
				parent.selection = RiftTabBarMath.selectionAfterClosing(
					index: index, count: tabs.count
				)
				.map { tabs[$0 < index ? $0 : $0 + 1].id }
			}
			tabs.remove(at: index)
			parent.tabs = tabs
		}
	}

	public func makeCoordinator() -> Coordinator { Coordinator(self) }

	public func makeNSView(context: Context) -> RiftTabListView<ID> {
		let coordinator = context.coordinator
		let view = RiftTabListView<ID>()
		view.setContentHuggingPriority(.required, for: .vertical)
		view.onSelect = { coordinator.parent.selection = $0 }
		view.onClose = { coordinator.close($0) }
		view.onCloseOthers = { id in
			for tab in coordinator.parent.tabs where tab.id != id && tab.isClosable {
				coordinator.close(tab.id)
			}
			coordinator.parent.selection = id
		}
		view.onMove = { id, index in
			var tabs = coordinator.parent.tabs
			guard let from = tabs.firstIndex(where: { $0.id == id }), tabs.indices.contains(index)
			else { return }
			tabs.insert(tabs.remove(at: from), at: index)
			coordinator.parent.tabs = tabs
		}
		view.onRename = { id, title in
			guard let index = coordinator.parent.tabs.firstIndex(where: { $0.id == id }) else {
				return
			}
			coordinator.parent.tabs[index].title = title
		}
		updateNSView(view, context: context)
		return view
	}

	public func updateNSView(_ view: RiftTabListView<ID>, context: Context) {
		let coordinator = context.coordinator
		coordinator.parent = self
		view.density = density
		view.surfaces = .modern(density)
		view.textSize = textSize
		view.theme = theme ?? environmentTheme
		view.paneDropGroup = dragGroup
		view.onTearOff = onTearOff.map { _ in { coordinator.parent.onTearOff?($0, $1) } }
		view.onPaneDrop = onPaneDrop.map { _ in { coordinator.parent.onPaneDrop?($0, $1) ?? false }
		}
		view.tabs = tabs
		view.selectedTab = selection
	}
}
