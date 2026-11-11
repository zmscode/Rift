import AppKit
import Rift

// MARK: - Pane content

/// A coloured pane with a text field (to show focus and first responder) and a scroll view with
/// always-visible scrollers (to show that scrollers hide while panes are being reshaped).
final class DemoPaneView: NSView {
	private let hue: CGFloat
	private let status = NSTextField(labelWithString: "")
	private var resizeObserver: RiftContainerAnimationObserver?

	init(name: String, hue: CGFloat) {
		self.hue = hue
		super.init(frame: .zero)
		wantsLayer = true
		setTranslucent(false)

		let label = NSTextField(labelWithString: name)
		label.font = .systemFont(ofSize: 20, weight: .semibold)
		label.textColor = NSColor(calibratedWhite: 0.1, alpha: 0.85)
		let field = NSTextField(string: "")
		field.placeholderString = "Type here…"
		status.font = .systemFont(ofSize: 11, weight: .medium)
		status.textColor = NSColor(calibratedWhite: 0.1, alpha: 0.7)

		let scroll = NSScrollView()
		scroll.hasVerticalScroller = true
		scroll.scrollerStyle = .legacy
		scroll.borderType = .noBorder
		scroll.drawsBackground = false
		let text = NSTextView()
		text.isEditable = false
		text.drawsBackground = false
		text.textColor = NSColor(calibratedWhite: 0.1, alpha: 0.6)
		text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
		text.string = (1...80).map { "\(name) line \($0)" }.joined(separator: "\n")
		text.autoresizingMask = [.width]
		scroll.documentView = text

		let stack = NSStackView(views: [label, field, status, scroll])
		stack.orientation = .vertical
		stack.spacing = 8
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			field.widthAnchor.constraint(equalToConstant: 160),
			scroll.widthAnchor.constraint(equalToConstant: 160),
			scroll.heightAnchor.constraint(equalToConstant: 60),
		])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func setTranslucent(_ translucent: Bool) {
		layer?.backgroundColor =
			NSColor(calibratedHue: hue, saturation: 0.35, brightness: 0.85, alpha: translucent ? 0.35 : 1)
			.cgColor
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard window != nil, resizeObserver == nil else { return }
		// What a terminal would do: hold its content while the container animates.
		let observer = RiftContainerAnimationObserver(view: self, handling: .holdContent)
		observer.onHoldChange = { [weak self] holding in
			self?.status.stringValue = holding ? "Holding during resize…" : ""
		}
		resizeObserver = observer
	}
}

// MARK: - Controls sidebar

/// A vertical list of titled sections holding buttons and switches.
final class ControlsSidebar: NSVisualEffectView {
	private let stack = NSStackView()
	let statusLabel = NSTextField(wrappingLabelWithString: "")

	override init(frame: NSRect) {
		super.init(frame: frame)
		material = .sidebar
		blendingMode = .behindWindow
		state = .followsWindowActiveState

		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 6
		stack.edgeInsets = NSEdgeInsets(top: 40, left: 14, bottom: 14, right: 14)
		let document = FlippedView()
		document.translatesAutoresizingMaskIntoConstraints = false
		stack.translatesAutoresizingMaskIntoConstraints = false
		document.addSubview(stack)

		let scroll = NSScrollView()
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.documentView = document
		scroll.translatesAutoresizingMaskIntoConstraints = false
		addSubview(scroll)

		statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
		statusLabel.textColor = .secondaryLabelColor
		statusLabel.translatesAutoresizingMaskIntoConstraints = false
		addSubview(statusLabel)

		NSLayoutConstraint.activate([
			scroll.topAnchor.constraint(equalTo: topAnchor),
			scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
			statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
			statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
			statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
			document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
			stack.topAnchor.constraint(equalTo: document.topAnchor),
			stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
			stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
		])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func section(_ title: String, _ hint: String? = nil) {
		if !stack.arrangedSubviews.isEmpty { stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!) }
		let label = NSTextField(labelWithString: title.uppercased())
		label.font = .systemFont(ofSize: 10, weight: .semibold)
		label.textColor = .secondaryLabelColor
		stack.addArrangedSubview(label)
		if let hint {
			let text = NSTextField(wrappingLabelWithString: hint)
			text.font = .systemFont(ofSize: 10)
			text.textColor = .tertiaryLabelColor
			text.preferredMaxLayoutWidth = 210
			stack.addArrangedSubview(text)
		}
	}

	/// A row of buttons that share the width.
	func buttons(_ items: [(String, () -> Void)]) {
		let row = NSStackView(
			views: items.map { title, action in ActionButton(title: title, action: action) })
		row.distribution = .fillEqually
		row.spacing = 4
		stack.addArrangedSubview(row)
		row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
	}

	/// ← ↑ ↓ → buttons.
	func arrows(_ action: @escaping (RiftDirection) -> Void) {
		buttons([
			("←", { action(.left) }), ("↑", { action(.up) }), ("↓", { action(.down) }),
			("→", { action(.right) }),
		])
	}

	func segmented(_ labels: [String], selected: Int, _ action: @escaping (Int) -> Void) {
		let control = ActionSegmented(labels: labels, action: action)
		control.selectedSegment = selected
		stack.addArrangedSubview(control)
		control.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
	}

	func toggle(_ title: String, isOn: Bool, _ action: @escaping (Bool) -> Void) {
		stack.addArrangedSubview(ActionCheckbox(title: title, isOn: isOn, action: action))
	}
}

final class FlippedView: NSView {
	override var isFlipped: Bool { true }
}

final class ActionButton: NSButton {
	private let handler: () -> Void
	init(title: String, action: @escaping () -> Void) {
		handler = action
		super.init(frame: .zero)
		self.title = title
		bezelStyle = .push
		controlSize = .small
		target = self
		self.action = #selector(fire)
	}
	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }
	@objc private func fire() { handler() }
}

final class ActionCheckbox: NSButton {
	private let handler: (Bool) -> Void
	init(title: String, isOn: Bool, action: @escaping (Bool) -> Void) {
		handler = action
		super.init(frame: .zero)
		setButtonType(.switch)
		self.title = title
		controlSize = .small
		state = isOn ? .on : .off
		target = self
		self.action = #selector(fire)
	}
	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }
	@objc private func fire() { handler(state == .on) }
}

final class ActionSegmented: NSSegmentedControl {
	private let handler: (Int) -> Void
	init(labels: [String], action: @escaping (Int) -> Void) {
		handler = action
		super.init(frame: .zero)
		segmentCount = labels.count
		for (i, label) in labels.enumerated() { setLabel(label, forSegment: i) }
		segmentDistribution = .fillEqually
		controlSize = .small
		target = self
		self.action = #selector(fire)
	}
	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }
	@objc private func fire() { handler(selectedSegment) }
}

// MARK: - Window content

/// The Rift view on the left and the controls sidebar on the right. The sidebar sits on the right
/// so the panes reach the window's top-left corner, where the window buttons are.
final class DemoWindowContent: NSView {
	let rift: RiftView<String>
	let sidebar = ControlsSidebar()
	private(set) var sidebarWidth: CGFloat = 250

	init(rift: RiftView<String>) {
		self.rift = rift
		super.init(frame: .zero)
		wantsLayer = true
		layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
		addSubview(rift)
		addSubview(sidebar)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		layoutParts(sidebar: sidebarWidth)
	}

	private func layoutParts(sidebar width: CGFloat) {
		rift.frame = riftFrame(sidebar: width)
		sidebar.frame = CGRect(x: bounds.width - width, y: 0, width: 250, height: bounds.height)
	}

	private func riftFrame(sidebar width: CGFloat) -> CGRect {
		CGRect(x: 0, y: 0, width: max(0, bounds.width - width), height: bounds.height)
	}

	/// Slides the controls away (or back), telling panes before and after so their content can
	/// hold still while the width animates.
	func toggleSidebar() {
		let target: CGFloat = sidebarWidth > 0 ? 0 : 250
		let frame = riftFrame(sidebar: target)
		rift.beginContainerAnimation(toWidth: frame.width)
		sidebarWidth = target
		NSAnimationContext.runAnimationGroup(
			{ context in
				context.duration = 0.5
				context.allowsImplicitAnimation = true
				rift.animator().frame = frame
				sidebar.animator().frame = CGRect(
					x: bounds.width - target, y: 0, width: 250, height: bounds.height)
			},
			completionHandler: { [weak self] in
				MainActor.assumeIsolated { self?.rift.endContainerAnimation() }
			})
	}
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
	private var windows: [NSWindow] = []
	private var counter = 0
	private var wrapsFocus = true

	private func nextPaneID() -> String {
		counter += 1
		return "Pane \(counter)"
	}

	private func startingLayout() -> RiftLayout<String> {
		let a = nextPaneID()
		let b = nextPaneID()
		let c = nextPaneID()
		let d = nextPaneID()
		return RiftLayout<String>.pane(a)
			.splitting(a, with: b, edge: .right)!
			.splitting(b, with: c, edge: .bottom)!
			.splitting(c, with: d, edge: .right)!
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		buildMenu()
		let window = makeWindow(
			layout: startingLayout(), frame: CGRect(x: 160, y: 160, width: 1150, height: 700))
		window.makeKeyAndOrderFront(nil)
		NSApp.activate()
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	private func makeRiftView(layout: RiftLayout<String>?) -> RiftView<String> {
		var configuration = RiftConfiguration()
		configuration.paneCornerRadius = 6
		configuration.metrics.dividerThickness = 4
		configuration.dividerColor = .clear
		configuration.windowStyle = .headless
		let view = RiftView<String>(layout: layout, configuration: configuration) { id in
			let number = Int(id.split(separator: " ").last ?? "0") ?? 0
			return DemoPaneView(name: id, hue: CGFloat((number * 37) % 100) / 100)
		}
		view.onLayoutChange = { [weak view] layout, _ in
			guard layout == nil, let window = view?.window else { return }
			Task { @MainActor in window.close() }
		}
		view.onTearOut = { [weak self] pane, content, point in
			guard let self else { return }
			let size = CGSize(width: 760, height: 420)
			let window = self.makeWindow(
				layout: nil,
				frame: CGRect(
					x: point.x - size.width / 2, y: point.y - size.height + 20, width: size.width,
					height: size.height))
			(window.contentView as? DemoWindowContent)?.rift.adopt(
				pane, content: content, reason: .tearOut)
			window.makeKeyAndOrderFront(nil)
		}
		return view
	}

	@discardableResult
	private func makeWindow(layout: RiftLayout<String>?, frame: CGRect) -> NSWindow {
		let window = NSWindow(
			contentRect: frame,
			styleMask: [.titled, .closable, .resizable, .miniaturizable],
			backing: .buffered,
			defer: false)
		window.title = "Rift"
		window.isReleasedWhenClosed = false
		window.delegate = self
		let view = makeRiftView(layout: layout)
		let content = DemoWindowContent(rift: view)
		window.contentView = content
		buildControls(content)
		windows.append(window)
		window.orderFront(nil)
		return window
	}

	func windowWillClose(_ notification: Notification) {
		guard let window = notification.object as? NSWindow else { return }
		windows.removeAll { $0 === window }
	}

	// MARK: Controls

	private func buildControls(_ content: DemoWindowContent) {
		let rift = content.rift
		let bar = content.sidebar
		func configure(_ change: (inout RiftConfiguration) -> Void) {
			var configuration = rift.configuration
			change(&configuration)
			rift.configuration = configuration
		}

		bar.section("Layout")
		bar.buttons([
			("Split →", { [unowned self] in rift.split(edge: .right, newPane: nextPaneID()) }),
			("Split ↓", { [unowned self] in rift.split(edge: .bottom, newPane: nextPaneID()) }),
		])
		bar.buttons([
			("Full width", { [unowned self] in rift.splitAll(edge: .right, newPane: nextPaneID()) }),
			("Close", { rift.close() }),
		])
		bar.buttons([
			("Reset", { [unowned self] in rift.setLayout(startingLayout(), animated: true) }),
			("Close others", { rift.closeOthers() }),
		])
		bar.buttons([("New window", { [unowned self] in newWindow(nil) })])

		bar.section(
			"Focus", "Nearest top-left corner among panes wholly past the edge. Closing a pane focuses the one before it.")
		bar.arrows { [unowned self] in rift.moveFocus($0, wraps: wrapsFocus) }
		bar.toggle("Wrap around edges", isOn: wrapsFocus) { [unowned self] in wrapsFocus = $0 }

		bar.section("Swap", "Overlapping neighbours first, then the nearest edge.")
		bar.arrows { rift.swap(toward: $0) }

		bar.section("Resize", "Moves the divider on that side.")
		bar.arrows { rift.resize(toward: $0) }

		bar.section(
			"Balance & zoom",
			"Balance counts a split across the axis as one slot. Spread two fingers over a pane to zoom it; pinch to restore.")
		bar.buttons([("Balance", { rift.balance() }), ("Zoom", { rift.toggleZoom() })])
		bar.toggle("Auto-balance on split and close", isOn: rift.configuration.autoBalance) { on in
			configure { $0.autoBalance = on }
		}

		bar.section("Motion", "Snappy: critically damped spring. Natural: slight overshoot.")
		bar.segmented(["Snappy", "Natural", "Off"], selected: 0) { index in
			configure { $0.animationStyle = [.snappy, .natural, .off][index] }
		}

		bar.section("Focus border", "Dims in background windows.")
		bar.segmented(["Glide", "Crossfade", "Off"], selected: 0) { index in
			configure { $0.focusBorderTransition = [.glide, .crossfade, .off][index] }
		}
		bar.toggle("Show focus border", isOn: rift.configuration.showsFocusBorder) { on in
			configure { $0.showsFocusBorder = on }
		}

		bar.section("Density", "Comfortable: 8pt gaps, rounded cards. Compact: touching panes with 1pt lines.")
		bar.segmented(["Demo", "Comfortable", "Compact"], selected: 0) { index in
			configure {
				switch index {
				case 1:
					$0.metrics.dividerThickness = 8
					$0.showsDividerLines = false
					$0.paneCornerRadius = 10
					$0.dropIndicatorCornerRadius = 8
				case 2:
					$0.metrics.dividerThickness = 1
					$0.showsDividerLines = true
					$0.dividerColor = NSColor.separatorColor.withAlphaComponent(0.7)
					$0.paneCornerRadius = 0
					$0.dropIndicatorCornerRadius = 0
				default:
					$0.metrics.dividerThickness = 4
					$0.dividerColor = .clear
					$0.paneCornerRadius = 6
					$0.dropIndicatorCornerRadius = 8
				}
			}
		}

		bar.section("Panes")
		bar.toggle("Fade unfocused panes", isOn: rift.configuration.inactivePaneAlpha < 1) { on in
			configure {
				$0.inactivePaneAlpha = on ? 0.7 : 1
				$0.inactiveWindowFocusedPaneAlpha = on ? 0.8 : 1
				$0.inactiveWindowPaneAlpha = on ? 0.5 : 1
			}
		}
		bar.toggle(
			"Hide scrollers while reshaping",
			isOn: rift.configuration.hidesScrollersDuringStructuralChanges
		) { on in configure { $0.hidesScrollersDuringStructuralChanges = on } }
		bar.toggle("Middle of a pane swaps on drop", isOn: rift.configuration.allowsCenterDrop) { on in
			configure { $0.allowsCenterDrop = on }
		}
		bar.toggle("Double-click a divider to centre it", isOn: rift.configuration.doubleClickCentersDivider) { on in
			configure { $0.doubleClickCentersDivider = on }
		}
		bar.toggle("Pinch to zoom", isOn: rift.configuration.allowsPinchToZoom) { on in
			configure { $0.allowsPinchToZoom = on }
		}
		bar.toggle("Glass", isOn: false) { on in
			configure {
				$0.glass.isEnabled = on
				$0.glass.cornerRadius = 10
				$0.paneCornerRadius = on ? 10 : 6
			}
			for id in rift.paneLayout?.paneIDs ?? [] {
				(rift.contentView(for: id) as? DemoPaneView)?.setTranslucent(on)
			}
		}

		bar.section("Window", "Headless keeps 76pt clear of the window buttons.")
		bar.toggle("Headless window", isOn: true) { on in
			configure { $0.windowStyle = on ? .headless : .standard }
		}
		bar.toggle("Pane headers", isOn: rift.configuration.showsPaneHeaders) { on in
			configure { $0.showsPaneHeaders = on }
		}
		bar.buttons([("Hide controls (⌃⌘S)", { [weak content] in content?.toggleSidebar() })])

		bar.section(
			"Try with the mouse",
			"Drag a pane by its top-left corner onto another pane's edge or middle. Drag a divider, or where two cross. Drop a pane outside the window to tear it out."
		)

		// Live status: focused pane, zoom and what is reshaping the panes.
		let update = { [weak rift, weak bar] in
			guard let rift, let bar else { return }
			var parts = ["Focus: \(rift.focusedPane ?? "none")"]
			if rift.zoomedPane != nil { parts.append("Zoomed") }
			let activity = rift.structuralActivity
			var reshaping: [String] = []
			if activity.contains(.structuralTransition) { reshaping.append("transition") }
			if activity.contains(.dividerDrag) { reshaping.append("divider drag") }
			if activity.contains(.paneDrag) { reshaping.append("pane drag") }
			if activity.contains(.windowLiveResize) { reshaping.append("live resize") }
			parts.append("Reshaping: " + (reshaping.isEmpty ? "–" : reshaping.joined(separator: ", ")))
			bar.statusLabel.stringValue = parts.joined(separator: "\n")
		}
		rift.onFocusChange = { _ in update() }
		rift.onZoomChange = { _ in update() }
		rift.onStructuralActivityChange = { _ in update() }
		update()
	}

	// MARK: Menu

	private var currentContent: DemoWindowContent? {
		NSApp.keyWindow?.contentView as? DemoWindowContent
	}

	@objc func newWindow(_ sender: Any?) {
		makeWindow(
			layout: .pane(nextPaneID()), frame: CGRect(x: 240, y: 240, width: 900, height: 520)
		)
		.makeKeyAndOrderFront(nil)
	}
	@objc func closePane(_ sender: Any?) {
		if let view = currentContent?.rift { view.close() } else { NSApp.keyWindow?.performClose(sender) }
	}
	@objc func splitRight(_ sender: Any?) {
		currentContent?.rift.split(edge: .right, newPane: nextPaneID())
	}
	@objc func splitDown(_ sender: Any?) {
		currentContent?.rift.split(edge: .bottom, newPane: nextPaneID())
	}
	@objc func toggleSidebar(_ sender: Any?) { currentContent?.toggleSidebar() }

	private func buildMenu() {
		let main = NSMenu()
		let appItem = NSMenuItem()
		let appMenu = NSMenu()
		appMenu.addItem(
			withTitle: "Quit Rift Demo", action: #selector(NSApplication.terminate(_:)),
			keyEquivalent: "q")
		appItem.submenu = appMenu
		main.addItem(appItem)

		let fileItem = NSMenuItem()
		let file = NSMenu(title: "File")
		add(file, "New Window", #selector(newWindow(_:)), "n")
		add(file, "Close Pane", #selector(closePane(_:)), "w")
		fileItem.submenu = file
		main.addItem(fileItem)

		let paneItem = NSMenuItem()
		let pane = NSMenu(title: "Pane")
		add(pane, "Split Right", #selector(splitRight(_:)), "d")
		add(pane, "Split Down", #selector(splitDown(_:)), "d", [.command, .shift])
		add(pane, "Hide Controls", #selector(toggleSidebar(_:)), "s", [.command, .control])
		paneItem.submenu = pane
		main.addItem(paneItem)
		NSApp.mainMenu = main
	}

	private func add(
		_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
		_ modifiers: NSEvent.ModifierFlags = [.command]
	) {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
		item.keyEquivalentModifierMask = modifiers
		item.target = self
		menu.addItem(item)
	}
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
