import AppKit
import Rift

/// A colourful pane with an editable field, so focus and first responder are easy to see.
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
		label.font = .systemFont(ofSize: 22, weight: .semibold)
		label.textColor = NSColor(calibratedWhite: 0.1, alpha: 0.85)
		let field = NSTextField(string: "")
		field.placeholderString = "Type here…"
		status.font = .systemFont(ofSize: 11, weight: .medium)
		status.textColor = NSColor(calibratedWhite: 0.1, alpha: 0.7)
		let stack = NSStackView(views: [label, field, status])
		stack.orientation = .vertical
		stack.spacing = 10
		stack.translatesAutoresizingMaskIntoConstraints = false
		addSubview(stack)
		NSLayoutConstraint.activate([
			stack.centerXAnchor.constraint(equalTo: centerXAnchor),
			stack.centerYAnchor.constraint(equalTo: centerYAnchor),
			field.widthAnchor.constraint(equalToConstant: 160),
		])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	/// With glass on, let the glass behind the pane show through.
	func setTranslucent(_ translucent: Bool) {
		layer?.backgroundColor =
			NSColor(calibratedHue: hue, saturation: 0.35, brightness: 0.85, alpha: translucent ? 0.35 : 1)
			.cgColor
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard window != nil, resizeObserver == nil else { return }
		// Show what a terminal would do: freeze while the container animates.
		let observer = RiftContainerAnimationObserver(view: self, handling: .holdContent)
		observer.onHoldChange = { [weak self] holding in
			self?.status.stringValue = holding ? "Holding during resize…" : ""
		}
		resizeObserver = observer
	}
}

/// The window's content: an optional sidebar strip and the Rift view.
final class DemoWindowContent: NSView {
	let rift: RiftView<String>
	private(set) var sidebarWidth: CGFloat = 0

	init(rift: RiftView<String>) {
		self.rift = rift
		super.init(frame: .zero)
		wantsLayer = true
		layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
		rift.autoresizingMask = [.width, .height]
		addSubview(rift)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		rift.frame = riftFrame(sidebar: sidebarWidth)
	}

	private func riftFrame(sidebar: CGFloat) -> CGRect {
		CGRect(x: sidebar, y: 0, width: max(0, bounds.width - sidebar), height: bounds.height)
	}

	/// Folds a 220pt sidebar in or out, telling panes before and after (like a sidebar fold).
	func toggleSidebar() {
		let target: CGFloat = sidebarWidth > 0 ? 0 : 220
		let frame = riftFrame(sidebar: target)
		rift.beginContainerAnimation(toWidth: frame.width)
		sidebarWidth = target
		NSAnimationContext.runAnimationGroup(
			{ context in
				context.duration = 0.6
				context.allowsImplicitAnimation = true
				rift.animator().frame = frame
			},
			completionHandler: { [weak self] in
				MainActor.assumeIsolated { self?.rift.endContainerAnimation() }
			})
	}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
	private var windows: [NSWindow] = []
	private var counter = 0

	private func nextPaneID() -> String {
		counter += 1
		return "Pane \(counter)"
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		buildMenu()
		let a = nextPaneID()
		let b = nextPaneID()
		let c = nextPaneID()
		let layout = RiftLayout<String>.pane(a)
			.splitting(a, with: b, edge: .right)!
			.splitting(b, with: c, edge: .bottom)!
		let first = makeWindow(
			layout: layout, frame: CGRect(x: 160, y: 220, width: 900, height: 560))
		_ = makeWindow(
			layout: .pane(nextPaneID()), frame: CGRect(x: 1080, y: 320, width: 480, height: 360))
		first.makeKeyAndOrderFront(nil)
		NSApp.activate()
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	private func makeRiftView(layout: RiftLayout<String>?) -> RiftView<String> {
		var configuration = RiftConfiguration()
		configuration.paneCornerRadius = 6
		configuration.metrics.dividerThickness = 4
		configuration.dividerColor = .clear
		configuration.inactivePaneAlpha = 0.85
		configuration.windowStyle = .headless
		configuration.headerHeight = 28
		let view = RiftView<String>(layout: layout, configuration: configuration) { id in
			let number = Int(id.split(separator: " ").last ?? "0") ?? 0
			return DemoPaneView(name: id, hue: CGFloat((number * 37) % 100) / 100)
		}
		view.onLayoutChange = { [weak view] layout, _ in
			// Close a window once its last pane has gone.
			guard layout == nil, let window = view?.window else { return }
			Task { @MainActor in window.close() }
		}
		view.onFocusChange = { [weak view] pane in view?.window?.subtitle = pane ?? "" }
		view.onStructuralActivityChange = { [weak view] activity in
			view?.window?.title = activity.isEmpty ? "Rift" : "Rift — reshaping"
		}
		view.onTearOut = { [weak self] pane, content, point in
			guard let self else { return }
			let size = CGSize(width: 520, height: 380)
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
		window.contentView = DemoWindowContent(rift: view)
		window.subtitle = view.focusedPane ?? ""
		windows.append(window)
		window.orderFront(nil)
		return window
	}

	func windowWillClose(_ notification: Notification) {
		guard let window = notification.object as? NSWindow else { return }
		windows.removeAll { $0 === window }
	}

	private var currentView: RiftView<String>? {
		(NSApp.keyWindow?.contentView as? DemoWindowContent)?.rift
	}

	// MARK: Menu actions

	@objc func newWindow(_ sender: Any?) {
		makeWindow(
			layout: .pane(nextPaneID()), frame: CGRect(x: 240, y: 240, width: 640, height: 420)
		)
		.makeKeyAndOrderFront(nil)
	}
	@objc func splitRight(_ sender: Any?) {
		currentView?.split(edge: .right, newPane: nextPaneID())
	}
	@objc func splitDown(_ sender: Any?) {
		currentView?.split(edge: .bottom, newPane: nextPaneID())
	}
	@objc func splitLeft(_ sender: Any?) { currentView?.split(edge: .left, newPane: nextPaneID()) }
	@objc func splitUp(_ sender: Any?) { currentView?.split(edge: .top, newPane: nextPaneID()) }
	@objc func splitFullRight(_ sender: Any?) {
		currentView?.splitAll(edge: .right, newPane: nextPaneID())
	}
	@objc func splitFullDown(_ sender: Any?) {
		currentView?.splitAll(edge: .bottom, newPane: nextPaneID())
	}
	@objc func closePane(_ sender: Any?) {
		if let view = currentView { view.close() } else { NSApp.keyWindow?.performClose(sender) }
	}
	@objc func focusLeft(_ sender: Any?) { currentView?.moveFocus(.left) }
	@objc func focusRight(_ sender: Any?) { currentView?.moveFocus(.right) }
	@objc func focusUp(_ sender: Any?) { currentView?.moveFocus(.up) }
	@objc func focusDown(_ sender: Any?) { currentView?.moveFocus(.down) }
	@objc func resizeLeft(_ sender: Any?) { currentView?.resize(toward: .left) }
	@objc func resizeRight(_ sender: Any?) { currentView?.resize(toward: .right) }
	@objc func resizeUp(_ sender: Any?) { currentView?.resize(toward: .up) }
	@objc func resizeDown(_ sender: Any?) { currentView?.resize(toward: .down) }
	@objc func swapLeft(_ sender: Any?) { currentView?.swap(toward: .left) }
	@objc func swapRight(_ sender: Any?) { currentView?.swap(toward: .right) }
	@objc func swapUp(_ sender: Any?) { currentView?.swap(toward: .up) }
	@objc func swapDown(_ sender: Any?) { currentView?.swap(toward: .down) }
	@objc func balance(_ sender: Any?) { currentView?.balance() }
	@objc func toggleZoom(_ sender: Any?) { currentView?.toggleZoom() }
	@objc func toggleHeaders(_ sender: Any?) {
		currentView?.configuration.showsPaneHeaders.toggle()
	}
	@objc func toggleSidebar(_ sender: Any?) {
		(NSApp.keyWindow?.contentView as? DemoWindowContent)?.toggleSidebar()
	}
	@objc func toggleGlass(_ sender: Any?) {
		guard let view = currentView else { return }
		var configuration = view.configuration
		configuration.glass.isEnabled.toggle()
		configuration.glass.cornerRadius = 10
		configuration.glass.outerRimColor = NSColor.white.withAlphaComponent(0.25)
		configuration.glass.outerRimWidth = 1
		configuration.glass.shadows = [RiftPaneShadow(opacity: 0.25, radius: 8, offset: CGSize(width: 0, height: -2))]
		configuration.paneCornerRadius = configuration.glass.isEnabled ? 10 : 6
		view.configuration = configuration
		for id in view.paneLayout?.paneIDs ?? [] {
			(view.contentView(for: id) as? DemoPaneView)?.setTranslucent(configuration.glass.isEnabled)
		}
	}
	@objc func toggleHeadless(_ sender: Any?) {
		guard let view = currentView else { return }
		view.configuration.windowStyle =
			view.configuration.windowStyle == .headless ? .standard : .headless
	}
	@objc func toggleAutoBalance(_ sender: Any?) {
		guard let view = currentView else { return }
		view.configuration.autoBalance.toggle()
		(sender as? NSMenuItem)?.state = view.configuration.autoBalance ? .on : .off
	}

	// MARK: Menu

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
		add(pane, "Split Left", #selector(splitLeft(_:)), "")
		add(pane, "Split Up", #selector(splitUp(_:)), "")
		add(
			pane, "Split Full Width (Right)", #selector(splitFullRight(_:)), "d",
			[.command, .option])
		add(
			pane, "Split Full Height (Down)", #selector(splitFullDown(_:)), "d",
			[.command, .option, .shift])
		pane.addItem(.separator())
		add(
			pane, "Focus Left", #selector(focusLeft(_:)), arrow(NSLeftArrowFunctionKey),
			[.command, .option])
		add(
			pane, "Focus Right", #selector(focusRight(_:)), arrow(NSRightArrowFunctionKey),
			[.command, .option])
		add(
			pane, "Focus Up", #selector(focusUp(_:)), arrow(NSUpArrowFunctionKey),
			[.command, .option])
		add(
			pane, "Focus Down", #selector(focusDown(_:)), arrow(NSDownArrowFunctionKey),
			[.command, .option])
		pane.addItem(.separator())
		add(
			pane, "Grow Left", #selector(resizeLeft(_:)), arrow(NSLeftArrowFunctionKey),
			[.command, .control])
		add(
			pane, "Grow Right", #selector(resizeRight(_:)), arrow(NSRightArrowFunctionKey),
			[.command, .control])
		add(
			pane, "Grow Up", #selector(resizeUp(_:)), arrow(NSUpArrowFunctionKey),
			[.command, .control])
		add(
			pane, "Grow Down", #selector(resizeDown(_:)), arrow(NSDownArrowFunctionKey),
			[.command, .control])
		pane.addItem(.separator())
		add(
			pane, "Swap Left", #selector(swapLeft(_:)), arrow(NSLeftArrowFunctionKey),
			[.command, .option, .shift])
		add(
			pane, "Swap Right", #selector(swapRight(_:)), arrow(NSRightArrowFunctionKey),
			[.command, .option, .shift])
		add(
			pane, "Swap Up", #selector(swapUp(_:)), arrow(NSUpArrowFunctionKey),
			[.command, .option, .shift])
		add(
			pane, "Swap Down", #selector(swapDown(_:)), arrow(NSDownArrowFunctionKey),
			[.command, .option, .shift])
		pane.addItem(.separator())
		add(pane, "Balance Panes", #selector(balance(_:)), "=", [.command, .control])
		add(pane, "Zoom Pane", #selector(toggleZoom(_:)), "\r", [.command, .shift])
		add(pane, "Toggle Headers", #selector(toggleHeaders(_:)), "h", [.command, .control])
		add(
			pane, "Toggle Sidebar (resize notices)", #selector(toggleSidebar(_:)), "s", [.command, .control])
		add(pane, "Toggle Glass", #selector(toggleGlass(_:)), "g", [.command, .control])
		add(
			pane, "Toggle Headless Window", #selector(toggleHeadless(_:)), "t",
			[.command, .control])
		add(pane, "Auto-Balance", #selector(toggleAutoBalance(_:)), "")
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

	private func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(UInt32(key))!)) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
