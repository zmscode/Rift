import AppKit
import Rift
import SwiftUI

/// The app's look and behaviour, turned into a `RiftConfiguration`.
struct FilesSettings: Equatable {
	enum Look: String, CaseIterable, Identifiable {
		case comfortable = "Cards"
		case compact = "Tiles"
		case plain = "Plain"
		var id: String { rawValue }
	}

	var look = Look.comfortable
	var motion = RiftAnimationStyle.snappy
	var transition = RiftPaneTransitionKind.popIn
	var border = RiftFocusBorderTransition.crossfade
	var gradientBorder = true
	var unfocusedFade = RiftInactivePaneFade.both
	var contentSizing = RiftPaneContentSizing.followsSurface
	var autoBalance = false
	var sidebarPosition = RiftSidebarPosition.left
	var keepsWindowWidth = true
	var swipe = RiftSidebarSwipe.swipe
	var borderColor = RiftFocusBorderColor.accent
	/// "auto" (Paper in light mode, Graphite in dark), or a theme's ID.
	var themeID = "auto"

	var theme: RiftThemeSelection {
		FilesThemes.all.first { $0.id == themeID }.map { RiftThemeSelection($0) } ?? .standard
	}
	var asksBeforeClosingBusyPanes = true
	/// Where the tabs go: rows in the sidebar, or a bar across the top.
	enum TabPlacement: String, CaseIterable {
		case sidebar = "Sidebar"
		case top = "Top"
	}
	var tabPlacement = TabPlacement.sidebar
	var sidebarTextSize = RiftSidebarTextSize.medium
	/// Pane headers as an invisible top strip (each pane draws its own title), or bars with a
	/// title, actions and close button.
	enum PaneHeaders: String, CaseIterable {
		case strip = "Strip"
		case bars = "Bars"
	}
	var paneHeaders = PaneHeaders.strip

	var density: RiftChromeDensity { look == .compact ? .compact : .comfortable }

	var configuration: RiftConfiguration {
		var c: RiftConfiguration
		switch look {
		case .comfortable: c = .comfortable
		case .compact: c = .compact
		case .plain:
			c = RiftConfiguration()
			c.metrics.dividerThickness = 6
			c.paneCornerRadius = 8
			c.layoutCornerRadius = 12
			c.dividerColor = .clear
		}
		c.windowStyle = .headless
		c.theme = theme
		c.titlebarMetrics = .sidebar(density)
		c.focusBorderPreset = borderColor
		c.animationStyle = motion
		c.paneTransition = transition
		c.focusBorderTransition = border
		c.focusBorderUsesGradient = gradientBorder
		c.inactivePaneFade = unfocusedFade
		c.paneContentSizing = contentSizing
		c.autoBalance = autoBalance
		c.showsPaneHeaders = paneHeaders == .bars
		if paneHeaders == .bars { c.headerHeight = 28 }
		return c
	}
}

/// Commands the menu bar sends to the focused window.
struct FilesActions {
	var split: (RiftEdge, PaneKind?) -> Void
	var close: () -> Void
	var closePane: (String) -> Void
	var closeOthers: (String?) -> Void
	var zoom: () -> Void
	var focus: (RiftDirection) -> Void
	var swap: (RiftDirection) -> Void
	var balance: () -> Void
	var toggleSidebar: () -> Void
	var setTheme: (String) -> Void
	var newTab: () -> Void
	var closeTab: () -> Void
	/// Selects the tab this many places along (wrapping).
	var selectTab: (Int) -> Void
	/// Opens a folder in the focused browser, or in a new tab.
	/// Opens the pane navigator.
	var showNavigator: () -> Void
	var openPlace: (URL, _ newTab: Bool) -> Void
	var goBack: () -> Void
	var goForward: () -> Void
	var goUp: () -> Void
	/// Lifts the focused pane into a floating layer, or docks it back.
	var toggleFloating: () -> Void
	/// Minimises the floating layer with the focused pane (or brings the last one back).
	var minimiseFloating: () -> Void
}

struct FilesActionsKey: FocusedValueKey { typealias Value = FilesActions }
extension FocusedValues {
	var files: FilesActions? {
		get { self[FilesActionsKey.self] }
		set { self[FilesActionsKey.self] = newValue }
	}
}

/// One tab: its own split layout of panes, focus and zoom.
@MainActor
struct FilesTab: Identifiable, @MainActor Equatable {
	private static var counter = 0

	let id: Int
	var layout: RiftLayout<String>?
	var focused: String?
	var zoomed: String?
	/// Panes floating above this tab's layout.
	var floating: [RiftFloatingLayer<String>] = []
	/// A name the user gave it; otherwise it is named after its browser's folder.
	var customTitle: String?
	let controller = RiftController<String>()

	init(layout: RiftLayout<String>?) {
		Self.counter += 1
		id = Self.counter
		self.layout = layout
		focused = layout?.firstPaneID
	}

	/// The browser that place clicks and ⌘[ go to: the focused one, else the first.
	var browser: String? {
		if let focused, PaneIDs.kind(of: focused) == .browser { return focused }
		return layout?.paneIDs.first { PaneIDs.kind(of: $0) == .browser }
	}

	var title: String {
		customTitle ?? browser.map(PaneIDs.title(of:)) ?? focused.map(PaneIDs.title(of:)) ?? "Empty"
	}

	static func == (a: FilesTab, b: FilesTab) -> Bool {
		a.id == b.id && a.layout == b.layout && a.focused == b.focused && a.zoomed == b.zoomed
			&& a.floating == b.floating
			&& a.customTitle == b.customTitle
	}
}

/// What a new window opens with: one pane, or a torn-off tab's whole layout.
@MainActor
enum WindowSeed {
	static func layout(from value: String?) -> RiftLayout<String> {
		guard let value else { return PaneIDs.startingLayout() }
		if value.hasPrefix("layout:"),
			let data = value.dropFirst("layout:".count).data(using: .utf8),
			let layout = try? JSONDecoder().decode(RiftLayout<String>.self, from: data)
		{
			return layout
		}
		return .pane(value)
	}

	static func value(for layout: RiftLayout<String>) -> String? {
		guard let data = try? JSONEncoder().encode(layout) else { return nil }
		return "layout:" + (String(data: data, encoding: .utf8) ?? "")
	}
}

/// One window: the places sidebar, a row of tabs, and each tab's split layout.
struct FilesWindow: View {
	@State private var tabs: [FilesTab]
	@State private var selection: Int?
	@State private var settings = FilesSettings()
	@State private var activity: RiftStructuralActivity = []
	@State private var sidebarCollapsed = false
	@State private var sidebarWidth = RiftSidebarMath.defaultWidth
	@State private var foldProgress: CGFloat = 0
	@State private var showsNavigator = false
	@Environment(\.openWindow) private var openWindow

	init(seed: String?) {
		let first = FilesTab(layout: WindowSeed.layout(from: seed))
		var tabs = [first]
		if seed == nil {
			let downloads = Files.favourites.first { $0.name == "Downloads" }?.url ?? Files.home
			tabs.append(FilesTab(layout: PaneIDs.measuringLayout(at: downloads)))
		}
		_tabs = State(initialValue: tabs)
		_selection = State(initialValue: first.id)
	}

	private var selectedIndex: Int? { tabs.firstIndex { $0.id == selection } }

	private var current: Binding<FilesTab>? {
		guard let index = selectedIndex else { return nil }
		return $tabs[index]
	}

	var body: some View {
		RiftSidebarSplitView(
			isCollapsed: $sidebarCollapsed, width: $sidebarWidth,
			position: settings.sidebarPosition, density: settings.density,
			preservesWindowWidth: settings.keepsWindowWidth, swipe: settings.swipe,
			animationStyle: settings.motion,
			onCollapseProgressChange: { foldProgress = $0 },
			onPositionChange: { settings.sidebarPosition = $0 },
			onDensityChange: { settings.look = $0 == .compact ? .compact : .comfortable },
			accessories: [
				RiftSidebarAccessory(symbolName: "plus.rectangle.on.rectangle", label: "New Tab") {
					actions.newTab()
				},
				RiftSidebarAccessory(symbolName: "rectangle.split.2x1", label: "Split Browser") {
					actions.split(.right, .browser)
				},
				RiftSidebarAccessory(
					symbolName: "arrow.up.left.and.arrow.down.right", label: "Zoom Pane"
				) {
					actions.zoom()
				},
				RiftSidebarAccessory(symbolName: "rectangle.split.3x1", label: "Balance") {
					actions.balance()
				},
			],
			toggleShortcut: "⌥⌘S",
			theme: settings.theme
		) {
			Navigator(
				tab: current?.wrappedValue,
				focused: current.map { $0.focused } ?? .constant(nil),
				settings: $settings, activity: activity, actions: actions,
				tabList: settings.tabPlacement == .sidebar ? AnyView(tabList) : nil)
		} content: {
			VStack(spacing: 0) {
				if settings.tabPlacement == .top { tabBar }
				ZStack {
					ForEach($tabs) { $tab in
						layoutView($tab).layoutHidden(tab.id != selection)
					}
				}
			}
		}
		.background {
			// The window's canvas, behind the surfaces.
			RiftThemeReader { theme in Color(rift: theme[.canvas]) }
				.environment(\.riftThemeSelection, settings.theme)
		}
		.environment(\.paneCommands, paneCommands)
		.preferredColorScheme(preferredScheme)
		.ignoresSafeArea()
		.frame(minHeight: 420)
		.focusedSceneValue(\.files, actions)
		.overlay(alignment: .top) {
			if showsNavigator { navigator.padding(.top, 60) }
		}
		// A tab whose last pane closed or moved away closes too, and the window with the last tab.
		.onChange(of: tabs.map { $0.layout == nil && $0.floating.isEmpty }) { _, empties in
			guard empties.contains(true) else { return }
			for id in tabs.filter({ $0.layout == nil && $0.floating.isEmpty }).map(\.id) {
				closeTab(id)
			}
		}
		.onAppear { Files.shared.record("window opened") }
	}

	/// The tabs as the bar and the sidebar list show them; moves and renames come back here,
	/// closes go through `closeTab`.
	private var tabItems: Binding<[RiftTab<Int>]> {
		Binding(
			get: {
				tabs.map { tab in
					RiftTab(
						id: tab.id, title: tab.title,
						symbolName: tab.browser == nil ? "square.split.2x1" : "folder",
						activity: busyActivity(in: tab))
				}
			},
			set: { new in
				var reordered: [FilesTab] = []
				for item in new {
					guard var tab = tabs.first(where: { $0.id == item.id }) else { continue }
					if item.title != tab.title {
						tab.customTitle = item.title
						Files.shared.record("renamed a tab to \(item.title)")
					}
					reordered.append(tab)
				}
				if reordered.map(\.id) != tabs.map(\.id) { Files.shared.record("moved a tab") }
				tabs = reordered
			})
	}

	private func tearOff(_ id: Int) {
		guard let tab = tabs.first(where: { $0.id == id }), let layout = tab.layout,
			let value = WindowSeed.value(for: layout)
		else { return }
		Files.shared.record("tore off \(tab.title)")
		closeTab(id)
		openWindow(value: value)
	}

	private func paneBecomesTab(_ pane: AnyHashable, at index: Int) -> Bool {
		guard let pane = pane.base as? String else { return false }
		let tab = FilesTab(layout: .pane(pane))
		tabs.insert(tab, at: min(index, tabs.count))
		selection = tab.id
		Files.shared.record("\(PaneIDs.title(of: pane)) became a tab")
		return true
	}

	private var tabBar: some View {
		RiftTabBar(
			tabs: tabItems, selection: $selection, density: settings.density, theme: settings.theme,
			onClose: { closeTab($0) }, onTearOff: { id, _ in tearOff(id) },
			onPaneDrop: { paneBecomesTab($0, at: $1) }, onNewTab: { newTab() }
		)
		.frame(height: RiftTabBarMath.buttonSize(density: settings.density) + 12)
		.padding(.horizontal, 6)
	}

	/// The tabs as sidebar rows.
	private var tabList: some View {
		RiftTabList(
			tabs: tabItems, selection: $selection, density: settings.density,
			textSize: settings.sidebarTextSize, theme: settings.theme,
			onClose: { closeTab($0) }, onTearOff: { id, _ in tearOff(id) },
			onPaneDrop: { paneBecomesTab($0, at: $1) })
	}

	private func layoutView(_ tab: Binding<FilesTab>) -> RiftLayoutView<String, FilesPane> {
		let id = tab.wrappedValue.id
		return RiftLayoutView(
			layout: tab.layout, focusedPane: tab.focused, zoomedPane: tab.zoomed,
			floating: tab.floating,
			configuration: settings.configuration, controller: tab.wrappedValue.controller,
			title: PaneIDs.title(of:),
			onStructuralActivityChange: { activity = $0 },
			onTearOut: { pane, _ in
				Files.shared.record("\(PaneIDs.title(of: pane)) got its own window")
				openWindow(value: pane)
			},
			dragPreview: { AnyView(DragCard(id: $0)) },
			paneActivity: { busyActivity(of: $0) },
			paneActions: { pane in paneActions(pane, tab: id) },
			paneMenu: { pane in paneMenu(pane, tab: id) },
			onRenamePane: { pane, name in
				Files.shared.paneNames[pane] = name
				Files.shared.record("renamed a pane to \(name)")
			}
		) { pane in
			FilesPane(
				pane: pane, tab: id, isTranslucent: settings.look != .plain, activity: activity,
				drawsTitle: settings.paneHeaders == .strip)
		}
	}

	private var paneCommands: PaneCommands {
		PaneCommands(
			openInNewTab: { url in openInNewTab(url) },
			addPane: { kind in actions.split(.right, kind) })
	}

	/// The navigator: every tab's panes, with minimaps.
	private var navigator: some View {
		RiftPaneNavigator(
			sections: tabs.map {
				.init(id: $0.id, title: $0.title, layout: $0.layout, floating: $0.floating)
			},
			current: current?.wrappedValue.focused, title: PaneIDs.title(of:),
			symbol: { PaneIDs.kind(of: $0).symbol },
			onPick: { tabID, pane in
				if let id = tabID.base as? Int, let index = tabs.firstIndex(where: { $0.id == id })
				{
					selection = id
					tabs[index].focused = pane
				}
				showsNavigator = false
			},
			onCancel: { showsNavigator = false }
		)
		.shadow(color: .black.opacity(0.3), radius: 20, y: 8)
	}

	/// Header buttons: browsers go up a folder; every pane can float (or dock) and zoom.
	private func paneActions(_ pane: String, tab: Int) -> [RiftPaneHeaderAction] {
		let controller = tabs.first { $0.id == tab }?.controller
		var actions: [RiftPaneHeaderAction] = []
		if PaneIDs.kind(of: pane) == .browser {
			actions.append(
				RiftPaneHeaderAction(symbolName: "arrow.turn.left.up", label: "Enclosing Folder") {
					Files.shared.goUp(pane)
				})
		}
		actions.append(
			RiftPaneHeaderAction(symbolName: "macwindow.on.rectangle", label: "Float or Dock") {
				_ = controller?.toggleFloating(pane)
			})
		actions.append(
			RiftPaneHeaderAction(symbolName: "arrow.up.left.and.arrow.down.right", label: "Zoom") {
				controller?.view?.toggleZoom(pane)
			})
		return actions
	}

	/// The right-click menu on a pane's header or top strip.
	private func paneMenu(_ pane: String, tab: Int) -> [RiftMenuItem] {
		let controller = tabs.first { $0.id == tab }?.controller
		let floats = controller?.view?.isFloating(pane) ?? false
		return [
			RiftMenuItem(floats ? "Dock Pane" : "Float Pane", systemImage: "macwindow.on.rectangle")
			{
				_ = controller?.toggleFloating(pane)
			},
			RiftMenuItem("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right") {
				controller?.view?.toggleZoom(pane)
			},
			.separator,
			RiftMenuItem("Split Right with Browser", systemImage: "rectangle.split.2x1") {
				let new = PaneIDs.make(.browser)
				Files.shared.setFolder(Files.shared.folder(of: pane), of: new)
				_ = controller?.view?.split(pane, edge: .right, newPane: new)
			},
			.separator,
			RiftMenuItem("Close Pane", systemImage: "xmark") { _ = controller?.close(pane) },
			RiftMenuItem("Close Other Panes") { _ = controller?.closeOthers(pane) },
		]
	}

	private func busyActivity(of pane: String) -> String? {
		guard settings.asksBeforeClosingBusyPanes, Files.shared.measuring.contains(pane) else {
			return nil
		}
		return "is still measuring"
	}

	/// A tab is busy when one of its panes is.
	private func busyActivity(in tab: FilesTab) -> String? {
		let busy = (tab.layout?.paneIDs ?? []).filter { busyActivity(of: $0) != nil }
		switch busy.count {
		case 0: return nil
		case 1: return busyActivity(of: busy[0])
		default: return "has \(busy.count) panes still measuring"
		}
	}

	private func insertTab(_ tab: FilesTab) {
		let at = (selectedIndex ?? tabs.count - 1) + 1
		tabs.insert(tab, at: min(at, tabs.count))
		selection = tab.id
	}

	private func newTab() {
		insertTab(FilesTab(layout: PaneIDs.browser(at: Files.home)))
		Files.shared.record("new tab")
	}

	private func openInNewTab(_ url: URL) {
		insertTab(FilesTab(layout: PaneIDs.browser(at: url)))
		Files.shared.record("opened \(url.displayName) in a new tab")
	}

	private func closeTab(_ id: Int) {
		guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
		if selection == id {
			selection = RiftTabBarMath.selectionAfterClosing(index: index, count: tabs.count)
				.map { tabs[$0 < index ? $0 : $0 + 1].id }
		}
		tabs.remove(at: index)
		if tabs.isEmpty { NSApp.keyWindow?.close() }
	}

	/// A single (non-automatic) theme sets the window's appearance to match it.
	private var preferredScheme: ColorScheme? {
		guard let theme = FilesThemes.all.first(where: { $0.id == settings.themeID }) else {
			return nil
		}
		return theme.appearance == .dark ? .dark : .light
	}

	private var actions: FilesActions {
		let tab = current?.wrappedValue
		let controller = tab?.controller
		let browser = tab?.browser
		return FilesActions(
			split: { edge, kind in
				let pane = PaneIDs.make(kind ?? .browser)
				if let browser, kind == nil || kind == .browser {
					Files.shared.setFolder(Files.shared.folder(of: browser), of: pane)
				}
				_ = controller?.split(edge: edge, newPane: pane)
			},
			close: { _ = controller?.close() },
			closePane: { _ = controller?.close($0) },
			closeOthers: { _ = controller?.closeOthers($0) },
			zoom: { controller?.toggleZoom() },
			focus: { _ = controller?.moveFocus($0) },
			swap: { _ = controller?.swap(toward: $0) },
			balance: { controller?.balance() },
			toggleSidebar: { sidebarCollapsed.toggle() },
			setTheme: { settings.themeID = $0 },
			newTab: { newTab() },
			closeTab: { if let selection { closeTab(selection) } },
			selectTab: { offset in
				guard let index = selectedIndex, !tabs.isEmpty else { return }
				selection = tabs[(index + offset + tabs.count) % tabs.count].id
			},
			showNavigator: { showsNavigator = true },
			openPlace: { url, newTab in
				if newTab || browser == nil {
					openInNewTab(url)
				} else if let browser {
					Files.shared.open(url, in: browser)
				}
			},
			goBack: { if let browser { Files.shared.goBack(browser) } },
			goForward: { if let browser { Files.shared.goForward(browser) } },
			goUp: { if let browser { Files.shared.goUp(browser) } },
			toggleFloating: {
				if controller?.toggleFloating() == true {
					Files.shared.record("floated or docked a pane")
				}
			},
			minimiseFloating: {
				guard let tab = current?.wrappedValue else { return }
				if let focused = tab.focused,
					let layer = tab.floating.first(where: {
						$0.layout.contains(focused) && !$0.isMinimised
					})
				{
					controller?.setMinimised(true, layer: layer.id)
					Files.shared.record("minimised a floating layer")
				} else if let layer = tab.floating.last(where: \.isMinimised) {
					controller?.setMinimised(false, layer: layer.id)
				}
			})
	}
}

@main
struct RiftFilesApp: App {
	@FocusedValue(\.files) private var actions

	var body: some Scene {
		WindowGroup("Rift Files", for: String.self) { $seed in
			FilesWindow(seed: seed)
		}
		.windowStyle(.hiddenTitleBar)
		.defaultSize(width: 1180, height: 760)
		.commands {
			CommandGroup(after: .newItem) {
				Button("New Tab") { actions?.newTab() }.keyboardShortcut("t")
				Button("Close Pane") { actions?.close() }.keyboardShortcut("w")
				Button("Close Tab") { actions?.closeTab() }
					.keyboardShortcut("w", modifiers: [.command, .shift])
				Divider()
				Button("Show Next Tab") { actions?.selectTab(1) }
					.keyboardShortcut("]", modifiers: [.command, .shift])
				Button("Show Previous Tab") { actions?.selectTab(-1) }
					.keyboardShortcut("[", modifiers: [.command, .shift])
			}
			CommandMenu("Go") {
				Button("Go to Pane…") { actions?.showNavigator() }.keyboardShortcut("p")
				Divider()
				Button("Back") { actions?.goBack() }.keyboardShortcut("[")
				Button("Forward") { actions?.goForward() }.keyboardShortcut("]")
				Button("Enclosing Folder") { actions?.goUp() }.keyboardShortcut(.upArrow)
				Divider()
				ForEach(Files.favourites + Files.locations) { place in
					Button(place.name) { actions?.openPlace(place.url, false) }
				}
			}
			CommandMenu("Layout") {
				Button("Split Right") { actions?.split(.right, nil) }.keyboardShortcut("d")
				Button("Split Down") { actions?.split(.bottom, nil) }
					.keyboardShortcut("d", modifiers: [.command, .shift])
				Menu("Split Right With") {
					ForEach(PaneKind.allCases) { kind in
						Button(kind.title) { actions?.split(.right, kind) }
					}
				}
				Divider()
				Button("Float or Dock Pane") { actions?.toggleFloating() }
					.keyboardShortcut("f", modifiers: [.command, .option])
				Button("Minimise Floating Layer") { actions?.minimiseFloating() }
					.keyboardShortcut("m", modifiers: [.command, .option])
				Button("Zoom Pane") { actions?.zoom() }.keyboardShortcut(
					.return, modifiers: [.command, .shift])
				Button("Balance") { actions?.balance() }.keyboardShortcut(
					"=", modifiers: [.command, .option])
				Button("Close Other Panes") { actions?.closeOthers(nil) }
					.keyboardShortcut("w", modifiers: [.command, .option])
				Divider()
				ForEach(Self.directions, id: \.0) { name, direction, key in
					Button("Focus \(name)") { actions?.focus(direction) }
						.keyboardShortcut(key, modifiers: [.command, .option])
				}
				ForEach(Self.directions, id: \.0) { name, direction, key in
					Button("Swap \(name)") { actions?.swap(direction) }
						.keyboardShortcut(key, modifiers: [.command, .control])
				}
			}
			CommandMenu("Theme") {
				Button("Automatic") { actions?.setTheme("auto") }
				Divider()
				ForEach(FilesThemes.all) { theme in
					Button(theme.name) { actions?.setTheme(theme.id) }
				}
			}
			CommandGroup(after: .sidebar) {
				Button("Toggle Sidebar") { actions?.toggleSidebar() }
					.keyboardShortcut("s", modifiers: [.command, .option])
			}
		}
	}

	private static let directions: [(String, RiftDirection, KeyEquivalent)] = [
		("Left", .left, .leftArrow), ("Right", .right, .rightArrow), ("Up", .up, .upArrow),
		("Down", .down, .downArrow),
	]
}
