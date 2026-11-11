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
}

struct WorkbenchActionsKey: FocusedValueKey { typealias Value = WorkbenchActions }
extension FocusedValues {
	var workbench: WorkbenchActions? {
		get { self[WorkbenchActionsKey.self] }
		set { self[WorkbenchActionsKey.self] = newValue }
	}
}

/// One workbench window: a navigator sidebar and the split layout of tools.
struct WorkbenchWindow: View {
	@State private var layout: RiftLayout<String>?
	@State private var focused: String?
	@State private var zoomed: String?
	@State private var settings = WorkbenchSettings()
	@State private var controller = RiftController<String>()
	@State private var activity: RiftStructuralActivity = []
	@State private var sidebarCollapsed = false
	@State private var sidebarWidth = RiftSidebarMath.defaultWidth
	@State private var foldProgress: CGFloat = 0
	@Environment(\.openWindow) private var openWindow

	init(initialPane: String?) {
		_layout = State(initialValue: initialPane.map { .pane($0) } ?? PaneIDs.startingLayout())
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
				layout: layout, focused: $focused, zoomed: zoomed, settings: $settings,
				activity: activity, foldProgress: foldProgress, actions: actions)
		} content: {
			RiftLayoutView(
				layout: $layout, focusedPane: $focused, zoomedPane: $zoomed,
				configuration: settings.configuration, controller: controller,
				title: PaneIDs.title(of:),
				onStructuralActivityChange: { activity = $0 },
				onTearOut: { pane, _ in openWindow(value: pane) },
				dragPreview: { AnyView(DragCard(id: $0)) },
				paneActivity: { id in
					guard settings.asksBeforeClosingBusyPanes else { return nil }
					switch PaneIDs.kind(of: id) {
					case .log: return "is still working"
					case .orbit: return "is still spinning"
					default: return nil
					}
				}
			) { pane in
				ToolPane(pane: pane, isTranslucent: settings.look != .plain, activity: activity)
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
		.onChange(of: layout == nil) { _, isEmpty in
			if isEmpty { NSApp.keyWindow?.close() }
		}
	}

	/// A single (non-automatic) theme sets the window's appearance to match it.
	private var preferredScheme: ColorScheme? {
		guard let theme = RiftTheme.builtIn.first(where: { $0.id == settings.themeID }) else {
			return nil
		}
		return theme.appearance == .dark ? .dark : .light
	}

	private var actions: WorkbenchActions {
		WorkbenchActions(
			split: { edge, kind in
				controller.split(edge: edge, newPane: kind.map(PaneIDs.make) ?? PaneIDs.makeNext())
			},
			close: { controller.close() },
			closePane: { controller.close($0) },
			closeOthers: { controller.closeOthers($0) },
			zoom: { controller.toggleZoom() },
			focus: { controller.moveFocus($0) },
			swap: { controller.swap(toward: $0) },
			balance: { controller.balance() },
			toggleSidebar: { sidebarCollapsed.toggle() },
			setTheme: { settings.themeID = $0 })
	}
}

@main
struct RiftWorkbenchApp: App {
	@FocusedValue(\.workbench) private var actions

	var body: some Scene {
		WindowGroup("Rift Workbench", for: String.self) { $pane in
			WorkbenchWindow(initialPane: pane)
		}
		.windowStyle(.hiddenTitleBar)
		.defaultSize(width: 1180, height: 760)
		.commands {
			CommandGroup(after: .newItem) {
				Button("Close Pane") { actions?.close() }.keyboardShortcut("w")
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
