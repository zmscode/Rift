import AppKit
import Rift

/// A colourful pane with an editable field, so focus and first responder are easy to see.
final class DemoPaneView: NSView {
	init(name: String, hue: CGFloat) {
		super.init(frame: .zero)
		wantsLayer = true
		layer?.backgroundColor =
			NSColor(calibratedHue: hue, saturation: 0.35, brightness: 0.85, alpha: 1).cgColor

		let label = NSTextField(labelWithString: name)
		label.font = .systemFont(ofSize: 22, weight: .semibold)
		label.textColor = NSColor(calibratedWhite: 0.1, alpha: 0.85)
		let field = NSTextField(string: "")
		field.placeholderString = "Type here…"
		let stack = NSStackView(views: [label, field])
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
		view.onTearOut = { [weak self] pane, content, point in
			guard let self else { return }
			let size = CGSize(width: 520, height: 380)
			let window = self.makeWindow(
				layout: nil,
				frame: CGRect(
					x: point.x - size.width / 2, y: point.y - size.height + 20, width: size.width,
					height: size.height))
			(window.contentView as? RiftView<String>)?.adopt(
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
		window.contentView = view
		window.subtitle = view.focusedPane ?? ""
		windows.append(window)
		window.orderFront(nil)
		return window
	}

	func windowWillClose(_ notification: Notification) {
		guard let window = notification.object as? NSWindow else { return }
		windows.removeAll { $0 === window }
	}

	private var currentView: RiftView<String>? { NSApp.keyWindow?.contentView as? RiftView<String> }

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
