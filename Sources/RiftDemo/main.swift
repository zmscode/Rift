import AppKit
import Rift
import SwiftUI

// MARK: - Pane identifiers

/// Hands out "Pane 1", "Pane 2", … across every window.
@MainActor
enum PaneNames {
	private static var counter = 0
	static func next() -> String {
		counter += 1
		return "Pane \(counter)"
	}

	static func startingLayout() -> RiftLayout<String> {
		let a = next(), b = next(), c = next(), d = next()
		return RiftLayout<String>.pane(a)
			.splitting(a, with: b, edge: .right)!
			.splitting(b, with: c, edge: .bottom)!
			.splitting(c, with: d, edge: .right)!
	}
}

// MARK: - Pane content

/// A coloured pane with a text field (focus) and an always-visible scroller (scroller hiding).
struct DemoPane: View {
	let pane: RiftPaneContext<String>
	let translucent: Bool

	private var hue: Double {
		let number = Int(pane.paneID.split(separator: " ").last ?? "0") ?? 0
		return Double((number * 37) % 100) / 100
	}

	@State private var text = ""

	var body: some View {
		ZStack {
			Color(hue: hue, saturation: 0.35, brightness: 0.85).opacity(translucent ? 0.35 : 1)
			VStack(spacing: 8) {
				Text(pane.paneID).font(.system(size: 20, weight: .semibold))
					.foregroundStyle(.black.opacity(0.85))
				TextField("Type here…", text: $text).frame(width: 160)
				Text(pane.presentation.isLayoutSettled ? " " : "Settling…")
					.font(.system(size: 11, weight: .medium)).foregroundStyle(.black.opacity(0.7))
				ScrollView {
					VStack(alignment: .leading, spacing: 0) {
						ForEach(1...80, id: \.self) { line in
							Text("\(pane.paneID) line \(line)").font(.system(size: 10, design: .monospaced))
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.scrollIndicators(.visible)
				.frame(width: 160, height: 60)
				.foregroundStyle(.black.opacity(0.6))
			}
		}
	}
}

// MARK: - Window

struct DemoActions {
	var split: (RiftEdge) -> Void
	var close: () -> Void
	var toggleControls: () -> Void
}

struct DemoActionsKey: FocusedValueKey { typealias Value = DemoActions }
extension FocusedValues {
	var demoActions: DemoActions? {
		get { self[DemoActionsKey.self] }
		set { self[DemoActionsKey.self] = newValue }
	}
}

enum SurfaceChoice: String, CaseIterable {
	case plain = "Plain"
	case comfortable = "Comfortable"
	case compact = "Compact"
}

struct DemoWindow: View {
	@State private var layout: RiftLayout<String>?
	@State private var focused: String?
	@State private var zoomed: String?
	@State private var configuration: RiftConfiguration
	@State private var controller = RiftController<String>()
	@State private var showsControls = true
	@State private var wrapsFocus = true
	@State private var surface = SurfaceChoice.plain
	@State private var activity: RiftStructuralActivity = []
	@Environment(\.openWindow) private var openWindow

	private static let sidebarWidth: CGFloat = 250

	init(initialPane: String?) {
		_layout = State(initialValue: initialPane.map { .pane($0) } ?? PaneNames.startingLayout())
		var configuration = RiftConfiguration()
		configuration.paneCornerRadius = 6
		configuration.metrics.dividerThickness = 4
		configuration.dividerColor = .clear
		configuration.windowStyle = .headless
		_configuration = State(initialValue: configuration)
	}

	var body: some View {
		GeometryReader { proxy in
			HStack(spacing: 0) {
				RiftLayoutView(
					layout: $layout, focusedPane: $focused, zoomedPane: $zoomed,
					configuration: configuration, controller: controller,
					onStructuralActivityChange: { activity = $0 },
					onTearOut: { pane, _ in openWindow(value: pane) }
				) { pane in
					DemoPane(pane: pane, translucent: surface == .comfortable)
				}
				if showsControls {
					controls.frame(width: Self.sidebarWidth).transition(.move(edge: .trailing))
				}
			}
			.focusedSceneValue(
				\.demoActions,
				DemoActions(
					split: { edge in controller.split(edge: edge, newPane: PaneNames.next()) },
					close: { controller.close() },
					toggleControls: { toggleControls(totalWidth: proxy.size.width) }))
		}
		.ignoresSafeArea()
		.frame(minWidth: 700, minHeight: 420)
		.onChange(of: layout == nil) { _, isEmpty in
			if isEmpty { NSApp.keyWindow?.close() }
		}
	}

	/// Folds the controls away (or back), telling the panes before and after.
	private func toggleControls(totalWidth: CGFloat) {
		let target = showsControls ? totalWidth : totalWidth - Self.sidebarWidth
		controller.beginContainerAnimation(toWidth: target)
		withAnimation(.easeInOut(duration: 0.5)) {
			showsControls.toggle()
		} completion: {
			controller.endContainerAnimation()
		}
	}

	private func configure(_ change: (inout RiftConfiguration) -> Void) {
		var copy = configuration
		change(&copy)
		configuration = copy
	}

	// MARK: Controls

	private var controls: some View {
		VStack(alignment: .leading, spacing: 0) {
			ScrollView {
				VStack(alignment: .leading, spacing: 6) {
					section("Layout")
					buttons([
						("Split →", { _ = controller.split(edge: .right, newPane: PaneNames.next()) }),
						("Split ↓", { _ = controller.split(edge: .bottom, newPane: PaneNames.next()) }),
					])
					buttons([
						("Full width", { _ = controller.splitAll(edge: .right, newPane: PaneNames.next()) }),
						("Close", { _ = controller.close() }),
					])
					buttons([
						("Reset", { layout = PaneNames.startingLayout() }),
						("Close others", { _ = controller.closeOthers() }),
					])
					buttons([("New window", { openWindow(value: PaneNames.next()) })])

					section(
						"Focus",
						"Nearest top-left corner among panes wholly past the edge. Closing a pane focuses the one before it.")
					arrows { _ = controller.moveFocus($0, wraps: wrapsFocus) }
					Toggle("Wrap around edges", isOn: $wrapsFocus)

					section("Swap", "Overlapping neighbours first, then the nearest edge.")
					arrows { _ = controller.swap(toward: $0) }

					section("Resize", "Moves the divider on that side.")
					arrows { _ = controller.resize(toward: $0) }

					section(
						"Balance & zoom",
						"Balance counts a split across the axis as one slot. Spread two fingers over a pane to zoom it; pinch to restore.")
					buttons([("Balance", { controller.balance() }), ("Zoom", { controller.toggleZoom() })])
					toggle("Auto-balance on split and close", \.autoBalance)

					section("Motion", "Snappy: critically damped spring. Natural: slight overshoot.")
					picker(["Snappy", "Natural", "Off"], values: [.snappy, .natural, .off], \.animationStyle)

					section("Focus border", "Dims in background windows.")
					picker(
						["Glide", "Crossfade", "Off"], values: [.glide, .crossfade, .off],
						\.focusBorderTransition)
					toggle("Show focus border", \.showsFocusBorder)

					section(
						"Pane surfaces",
						"Comfortable: glass cards with 8pt gaps. Compact: touching panes with 1pt lines. Plain: the demo's own coloured panes.")
					Picker("", selection: $surface) {
						ForEach(SurfaceChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
					}
					.pickerStyle(.segmented).labelsHidden()
					.onChange(of: surface) { _, choice in applySurface(choice) }

					section("Divider lines", "Blend mode for the lines in compact density.")
					picker(
						["Normal", "Darker", "Lighter", "Overlay"],
						values: [.normal, .plusDarker, .plusLighter, .overlay], \.dividerBlendMode)

					section("Panes")
					toggle("Hide scrollers while reshaping", \.hidesScrollersDuringStructuralChanges)
					toggle("Middle of a pane swaps on drop", \.allowsCenterDrop)
					toggle("Double-click a divider to centre it", \.doubleClickCentersDivider)
					toggle("Pinch to zoom", \.allowsPinchToZoom)

					section("Window", "Headless keeps 76pt clear of the window buttons.")
					Toggle(
						"Headless window",
						isOn: Binding(
							get: { configuration.windowStyle == .headless },
							set: { on in configure { $0.windowStyle = on ? .headless : .standard } }))
					toggle("Pane headers", \.showsPaneHeaders)
					Toggle(
						"Top padding without headers",
						isOn: Binding(
							get: { configuration.headerlessTopInset > 0 },
							set: { on in configure { $0.headerlessTopInset = on ? 28 : 0 } }))
					Text("⌃⌘S hides these controls.").font(.caption).foregroundStyle(.secondary)

					section(
						"Try with the mouse",
						"Drag a pane by its top-left corner onto another pane's edge or middle. Drag a divider, or where two cross. Drop a pane outside the window to tear it out.")
				}
				.padding(.horizontal, 14)
				.padding(.top, 40)
				.padding(.bottom, 14)
				.controlSize(.small)
				.toggleStyle(.checkbox)
			}
			Text(status).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
				.padding(.horizontal, 14).padding(.bottom, 12)
		}
		.frame(maxHeight: .infinity)
		.background(.regularMaterial)
	}

	private var status: String {
		var lines = ["Focus: \(focused ?? "none")"]
		if let zoomed { lines.append("Zoomed: \(zoomed)") }
		var reshaping: [String] = []
		if activity.contains(.structuralTransition) { reshaping.append("transition") }
		if activity.contains(.dividerDrag) { reshaping.append("divider drag") }
		if activity.contains(.paneDrag) { reshaping.append("pane drag") }
		if activity.contains(.windowLiveResize) { reshaping.append("live resize") }
		lines.append("Reshaping: " + (reshaping.isEmpty ? "–" : reshaping.joined(separator: ", ")))
		return lines.joined(separator: "\n")
	}

	private func applySurface(_ choice: SurfaceChoice) {
		configure {
			switch choice {
			case .comfortable:
				$0.metrics.dividerThickness = 8
				$0.showsDividerLines = false
				$0.paneCornerRadius = 10
				$0.dropIndicatorCornerRadius = 8
				$0.paneSurface = RiftPaneSurface(.modern(.comfortable))
			case .compact:
				$0.metrics.dividerThickness = 1
				$0.showsDividerLines = true
				$0.dividerColor = NSColor.separatorColor.withAlphaComponent(0.7)
				$0.paneCornerRadius = 0
				$0.dropIndicatorCornerRadius = 0
				$0.paneSurface = RiftPaneSurface(.modern(.compact))
			case .plain:
				$0.metrics.dividerThickness = 4
				$0.dividerColor = .clear
				$0.paneCornerRadius = 6
				$0.dropIndicatorCornerRadius = 8
				$0.paneSurface = nil
			}
		}
	}

	// MARK: Control helpers

	private func section(_ title: String, _ hint: String? = nil) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(title.uppercased()).font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.secondary)
			if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary) }
		}
		.padding(.top, 10)
	}

	private func buttons(_ items: [(String, () -> Void)]) -> some View {
		HStack(spacing: 4) {
			ForEach(items.indices, id: \.self) { index in
				Button(action: items[index].1) {
					Text(items[index].0).frame(maxWidth: .infinity)
				}
			}
		}
	}

	private func arrows(_ action: @escaping (RiftDirection) -> Void) -> some View {
		buttons([
			("←", { action(.left) }), ("↑", { action(.up) }), ("↓", { action(.down) }),
			("→", { action(.right) }),
		])
	}

	private func toggle(_ title: String, _ key: WritableKeyPath<RiftConfiguration, Bool>) -> some View {
		Toggle(
			title,
			isOn: Binding(
				get: { configuration[keyPath: key] },
				set: { value in configure { $0[keyPath: key] = value } }))
	}

	private func picker<Value: Hashable>(
		_ labels: [String], values: [Value], _ key: WritableKeyPath<RiftConfiguration, Value>
	) -> some View {
		Picker(
			"",
			selection: Binding(
				get: { configuration[keyPath: key] },
				set: { value in configure { $0[keyPath: key] = value } })
		) {
			ForEach(labels.indices, id: \.self) { Text(labels[$0]).tag(values[$0]) }
		}
		.pickerStyle(.segmented).labelsHidden()
	}
}

// MARK: - App

struct RiftDemoApp: App {
	@FocusedValue(\.demoActions) private var actions

	var body: some Scene {
		WindowGroup("Rift") {
			DemoWindow(initialPane: nil)
		}
		.windowStyle(.hiddenTitleBar)
		.defaultSize(width: 1150, height: 700)
		.commands {
			CommandGroup(after: .newItem) {
				Button("Close Pane") { actions?.close() }.keyboardShortcut("w")
			}
			CommandMenu("Pane") {
				Button("Split Right") { actions?.split(.right) }.keyboardShortcut("d")
				Button("Split Down") { actions?.split(.bottom) }
					.keyboardShortcut("d", modifiers: [.command, .shift])
				Button("Hide Controls") { actions?.toggleControls() }
					.keyboardShortcut("s", modifiers: [.command, .control])
			}
		}

		WindowGroup("Rift", for: String.self) { $pane in
			DemoWindow(initialPane: pane)
		}
		.windowStyle(.hiddenTitleBar)
		.defaultSize(width: 900, height: 520)
	}
}

RiftDemoApp.main()
