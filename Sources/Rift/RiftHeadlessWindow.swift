import AppKit

/// Turns a normal titled window into a "headless" one: no visible titlebar or title, content
/// running edge to edge, and the system close/minimize/zoom buttons kept but centred in a row of
/// `rowHeight` points at the top, so they can sit inside your own header.
///
/// Only public AppKit API is used. The buttons' titlebar container is resized with ordinary
/// `NSView` frame calls, and re-applied whenever AppKit lays the titlebar out again.
@MainActor
public final class RiftHeadlessWindow {
	public private(set) weak var window: NSWindow?

	/// Height of the row the buttons are centred in, measured from the top of the window.
	public var rowHeight: CGFloat { didSet { if rowHeight != oldValue { layoutButtons() } } }
	/// Extra horizontal shift for the button group.
	public var horizontalOffset: CGFloat {
		didSet { if horizontalOffset != oldValue { layoutButtons() } }
	}
	/// Called after the buttons move, so views can reserve space for them.
	public var onLayout: (() -> Void)?

	private struct Saved {
		var styleMask: NSWindow.StyleMask
		var titleVisibility: NSWindow.TitleVisibility
		var titlebarAppearsTransparent: Bool
		var titlebarSeparatorStyle: NSTitlebarSeparatorStyle
		var toolbar: NSToolbar?
	}

	private var saved: Saved?
	private var originalButtonX: [NSWindow.ButtonType: CGFloat] = [:]
	private var observers: [NSObjectProtocol] = []
	private var isLayingOut = false

	private static let buttonTypes: [NSWindow.ButtonType] = [
		.closeButton, .miniaturizeButton, .zoomButton,
	]

	public init(window: NSWindow, rowHeight: CGFloat = 28, horizontalOffset: CGFloat = 0) {
		self.window = window
		self.rowHeight = rowHeight
		self.horizontalOffset = horizontalOffset
		apply()
	}

	/// The button group's frame in window coordinates (bottom-left origin), or `nil` when the
	/// buttons aren't in the top row (for example in full screen).
	public var buttonGroupFrame: CGRect? {
		guard let window, !window.styleMask.contains(.fullScreen) else { return nil }
		let frames = Self.buttonTypes.compactMap { type -> CGRect? in
			guard let button = window.standardWindowButton(type), !button.isHidden,
				button.superview != nil
			else { return nil }
			return button.convert(button.bounds, to: nil)
		}
		return frames.dropFirst().reduce(frames.first) { $0?.union($1) }
	}

	private func apply() {
		guard let window, saved == nil else { return }
		saved = Saved(
			styleMask: window.styleMask,
			titleVisibility: window.titleVisibility,
			titlebarAppearsTransparent: window.titlebarAppearsTransparent,
			titlebarSeparatorStyle: window.titlebarSeparatorStyle,
			toolbar: window.toolbar)
		window.styleMask.insert([.titled, .fullSizeContentView])
		window.titleVisibility = .hidden
		window.titlebarAppearsTransparent = true
		window.titlebarSeparatorStyle = .none
		window.toolbar = nil

		let center = NotificationCenter.default
		let names: [Notification.Name] = [
			NSWindow.didResizeNotification,
			NSWindow.didEndLiveResizeNotification,
			NSWindow.didBecomeKeyNotification,
			NSWindow.didResignKeyNotification,
			NSWindow.didEnterFullScreenNotification,
			NSWindow.didExitFullScreenNotification,
			NSWindow.didChangeBackingPropertiesNotification,
		]
		for name in names {
			observers.append(
				center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.layoutButtons() }
				})
		}
		if let container = titlebarContainer {
			// AppKit re-lays out the titlebar on many occasions; put the buttons back each time.
			container.postsFrameChangedNotifications = true
			observers.append(
				center.addObserver(
					forName: NSView.frameDidChangeNotification, object: container, queue: .main
				) { [weak self] _ in
					MainActor.assumeIsolated { self?.layoutButtons() }
				})
		}
		layoutButtons()
	}

	/// Puts the window back the way it was.
	public func restore() {
		observers.forEach(NotificationCenter.default.removeObserver)
		observers.removeAll()
		guard let window, let saved else { return }
		for type in Self.buttonTypes {
			if let button = window.standardWindowButton(type), let x = originalButtonX[type] {
				button.setFrameOrigin(CGPoint(x: x, y: button.frame.origin.y))
			}
		}
		window.styleMask = saved.styleMask
		window.titleVisibility = saved.titleVisibility
		window.titlebarAppearsTransparent = saved.titlebarAppearsTransparent
		window.titlebarSeparatorStyle = saved.titlebarSeparatorStyle
		window.toolbar = saved.toolbar
		// Let AppKit recompute the titlebar's own geometry.
		titlebarContainer?.superview?.needsLayout = true
		window.contentView?.superview?.layoutSubtreeIfNeeded()
		self.saved = nil
		onLayout?()
	}

	/// The view that holds the titlebar (and so the buttons).
	private var titlebarContainer: NSView? {
		window?.standardWindowButton(.closeButton)?.superview?.superview
	}

	private func layoutButtons() {
		guard !isLayingOut, saved != nil, let window else { return }
		defer { onLayout?() }
		guard !window.styleMask.contains(.fullScreen),
			let close = window.standardWindowButton(.closeButton),
			let titlebarView = close.superview,
			let container = titlebarView.superview,
			let frameView = container.superview
		else { return }
		isLayingOut = true
		defer { isLayingOut = false }

		let height = max(rowHeight, close.frame.height + 2)
		let containerFrame = CGRect(
			x: 0,
			y: frameView.isFlipped ? 0 : frameView.bounds.height - height,
			width: frameView.bounds.width,
			height: height)
		if container.frame != containerFrame { container.frame = containerFrame }
		if titlebarView.frame != container.bounds { titlebarView.frame = container.bounds }

		for type in Self.buttonTypes {
			guard let button = window.standardWindowButton(type) else { continue }
			let x = originalButtonX[type] ?? button.frame.origin.x
			originalButtonX[type] = x
			let origin = CGPoint(
				x: x + horizontalOffset,
				y: ((titlebarView.bounds.height - button.frame.height) / 2).rounded())
			if button.frame.origin != origin { button.setFrameOrigin(origin) }
		}
	}

	/// Performs the user's chosen titlebar double-click action (System Settings › Desktop & Dock).
	///
	/// The window's frame view handles it when it can, so the result matches a real titlebar.
	/// Otherwise the System Settings preference is read and applied here.
	public static func performTitlebarDoubleClick(on window: NSWindow, event: NSEvent) {
		if let frameView = window.contentView?.superview {
			let withModifiers = NSSelectorFromString("_handlePossibleDoubleClickWithModifiers:")
			let forEvent = NSSelectorFromString("_handlePossibleDoubleClickForEvent:")
			if frameView.responds(to: withModifiers) {
				typealias Handler = @convention(c) (AnyObject, Selector, UInt) -> Void
				let handler = unsafeBitCast(frameView.method(for: withModifiers), to: Handler.self)
				handler(frameView, withModifiers, event.modifierFlags.rawValue)
				return
			}
			if frameView.responds(to: forEvent) {
				_ = frameView.perform(forEvent, with: event)
				return
			}
		}
		let defaults = UserDefaults.standard
		switch defaults.string(forKey: "AppleActionOnDoubleClick") {
		case "None":
			return
		case "Minimize":
			window.miniaturize(nil)
		case "Maximize", "Fill":
			window.zoom(nil)
		default:
			if defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") {
				window.miniaturize(nil)
			} else {
				window.zoom(nil)
			}
		}
	}
}
