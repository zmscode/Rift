import AppKit
import Rift
import SwiftUI

/// The workbench's look and behaviour, turned into a `RiftConfiguration`.
struct WorkbenchSettings: Equatable {
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
	/// "auto" (Paper in light mode, Graphite in dark), or a built-in theme's ID.
	var themeID = "auto"

	var theme: RiftThemeSelection {
		RiftTheme.builtIn.first { $0.id == themeID }.map { RiftThemeSelection($0) } ?? .standard
	}
	var asksBeforeClosingBusyPanes = true

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
		return c
	}
}

/// Commands the menu bar sends to the focused workbench window.
struct WorkbenchActions {
	var split: (RiftEdge, ToolKind?) -> Void
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
}

struct WorkbenchActionsKey: FocusedValueKey { typealias Value = WorkbenchActions }
extension FocusedValues {
	var workbench: WorkbenchActions? {
		get { self[WorkbenchActionsKey.self] }
		set { self[WorkbenchActionsKey.self] = newValue }
	}
}

/// One tab: its own split layout of tools, focus and zoom.
@MainActor
struct WorkbenchTab: Identifiable, @MainActor Equatable {
	private static var counter = 0

	let id: Int
	var layout: RiftLayout<String>?
	var focused: String?
	var zoomed: String?
	/// A name the user gave it; otherwise it is named after its focused tool.
	var customTitle: String?
	let controller = RiftController<String>()

	init(layout: RiftLayout<String>?) {
		Self.counter += 1
		id = Self.counter
		self.layout = layout
		focused = layout?.firstPaneID
	}

	var title: String {
		customTitle ?? (focused ?? layout?.firstPaneID).map(PaneIDs.title(of:)) ?? "Empty"
	}

	static func == (a: WorkbenchTab, b: WorkbenchTab) -> Bool {
		a.id == b.id && a.layout == b.layout && a.focused == b.focused && a.zoomed == b.zoomed
			&& a.customTitle == b.customTitle
	}
}

/// What a new window opens with: one pane, or a torn-off tab's whole layout.
@MainActor
enum WorkbenchSeed {
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

/// One workbench window: a navigator sidebar, a row of tabs, and each tab's split layout.
struct WorkbenchWindow: View {
	@State private var tabs: [WorkbenchTab]
	@State private var selection: Int?
	@State private var settings = WorkbenchSettings()
	@State private var activity: RiftStructuralActivity = []
	@State private var sidebarCollapsed = false
	@State private var sidebarWidth = RiftSidebarMath.defaultWidth
	@State private var foldProgress: CGFloat = 0
	@Environment(\.openWindow) private var openWindow

	init(seed: String?) {
		let first = WorkbenchTab(layout: WorkbenchSeed.layout(from: seed))
		var tabs = [first]
		if seed == nil {
			let notes = PaneIDs.make(.notes)
			tabs.append(WorkbenchTab(layout: RiftLayout<String>.pane(notes)))
		}
		_tabs = State(initialValue: tabs)
		_selection = State(initialValue: first.id)
	}

	private var selectedIndex: Int? { tabs.firstIndex { $0.id == selection } }

	private var current: Binding<WorkbenchTab>? {
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
				RiftSidebarAccessory(symbolName: "square.and.pencil", label: "New Notes") {
					actions.split(.right, .notes)
				},
				RiftSidebarAccessory(symbolName: "arrow.up.left.and.arrow.down.right", label: "Zoom Pane") {
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
				layout: current?.wrappedValue.layout,
				focused: current.map { $0.focused } ?? .constant(nil),
				zoomed: current?.wrappedValue.zoomed, settings: $settings,
				activity: activity, foldProgress: foldProgress, actions: actions)
		} content: {
			VStack(spacing: 0) {
				tabBar
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
		.preferredColorScheme(preferredScheme)
		.ignoresSafeArea()
		.frame(minHeight: 420)
		.focusedSceneValue(\.workbench, actions)
		// A tab whose last pane closed or moved away closes too, and the window with the last tab.
		.onChange(of: tabs.map { $0.layout == nil }) { _, empties in
			guard empties.contains(true) else { return }
			let closing = tabs.filter { $0.layout == nil }.map(\.id)
			for id in closing { closeTab(id) }
		}
	}

	private var tabBar: some View {
		RiftTabBar(
			tabs: Binding(
				get: {
					tabs.map { tab in
						RiftTab(id: tab.id, title: tab.title, activity: busyActivity(in: tab))
					}
				},
				set: { new in
					// Moves and renames come back here; closes go through `onClose`.
					var reordered: [WorkbenchTab] = []
					for item in new {
						guard var tab = tabs.first(where: { $0.id == item.id }) else { continue }
						if item.title != tab.title { tab.customTitle = item.title }
						reordered.append(tab)
					}
					tabs = reordered
				}),
			selection: $selection, density: settings.density, theme: settings.theme,
			onClose: { closeTab($0) },
			onTearOff: { id, _ in
				guard let tab = tabs.first(where: { $0.id == id }), let layout = tab.layout,
					let value = WorkbenchSeed.value(for: layout)
				else { return }
				closeTab(id)
				openWindow(value: value)
			},
			onPaneDrop: { pane, index in
				guard let pane = pane.base as? String else { return false }
				let tab = WorkbenchTab(layout: .pane(pane))
				tabs.insert(tab, at: min(index, tabs.count))
				selection = tab.id
				return true
			},
			onNewTab: { newTab() }
		)
		.frame(height: RiftTabBarMath.buttonSize(density: settings.density) + 12)
		.padding(.horizontal, 6)
	}

	private func layoutView(_ tab: Binding<WorkbenchTab>) -> RiftLayoutView<String, ToolPane> {
		RiftLayoutView(
			layout: tab.layout, focusedPane: tab.focused, zoomedPane: tab.zoomed,
			configuration: settings.configuration, controller: tab.wrappedValue.controller,
			title: PaneIDs.title(of:),
			onStructuralActivityChange: { activity = $0 },
			onTearOut: { pane, _ in openWindow(value: pane) },
			dragPreview: { AnyView(DragCard(id: $0)) },
			paneActivity: { busyActivity(of: $0) }
		) { pane in
			ToolPane(pane: pane, isTranslucent: settings.look != .plain, activity: activity)
		}
	}

	private func busyActivity(of pane: String) -> String? {
		guard settings.asksBeforeClosingBusyPanes else { return nil }
		switch PaneIDs.kind(of: pane) {
		case .log: return "is still working"
		case .orbit: return "is still spinning"
		default: return nil
		}
	}

	/// A tab is busy when one of its panes is.
	private func busyActivity(in tab: WorkbenchTab) -> String? {
		let busy = (tab.layout?.paneIDs ?? []).filter { busyActivity(of: $0) != nil }
		switch busy.count {
		case 0: return nil
		case 1: return busyActivity(of: busy[0])
		default: return "has \(busy.count) busy tools"
		}
	}

	private func newTab() {
		let tab = WorkbenchTab(layout: .pane(PaneIDs.makeNext()))
		let at = (selectedIndex ?? tabs.count - 1) + 1
		tabs.insert(tab, at: min(at, tabs.count))
		selection = tab.id
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
		guard let theme = RiftTheme.builtIn.first(where: { $0.id == settings.themeID }) else {
			return nil
		}
		return theme.appearance == .dark ? .dark : .light
	}

	private var actions: WorkbenchActions {
		let controller = current?.wrappedValue.controller
		return WorkbenchActions(
			split: { edge, kind in
				_ = controller?.split(
					edge: edge, newPane: kind.map(PaneIDs.make) ?? PaneIDs.makeNext())
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
			})
	}
}

@main
struct RiftWorkbenchApp: App {
	@FocusedValue(\.workbench) private var actions

	var body: some Scene {
		WindowGroup("Rift Workbench", for: String.self) { $seed in
			WorkbenchWindow(seed: seed)
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
			CommandMenu("Layout") {
				Button("Split Right") { actions?.split(.right, nil) }.keyboardShortcut("d")
				Button("Split Down") { actions?.split(.bottom, nil) }
					.keyboardShortcut("d", modifiers: [.command, .shift])
				Menu("Split Right With") {
					ForEach(ToolKind.allCases) { kind in
						Button(kind.title) { actions?.split(.right, kind) }
					}
				}
				Divider()
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
				ForEach(RiftTheme.builtIn) { theme in
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

