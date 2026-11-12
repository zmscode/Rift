import AppKit
import RiftCore

/// A small grip that starts a pane drag when the header itself moves the window.
final class RiftHeaderGripView: NSImageView {
	var onMouseDown: ((NSEvent) -> Void)?

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		image = NSImage(
			systemSymbolName: "line.3.horizontal", accessibilityDescription: "Move Pane")
		symbolConfiguration = .init(pointSize: 10, weight: .semibold)
		contentTintColor = .tertiaryLabelColor
		imageScaling = .scaleProportionallyDown
		toolTip = "Drag to move this pane"
		setAccessibilityLabel("Move Pane")
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
	override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// The strip at the top of a pane: title, close button, and the handle for dragging the pane.
/// A button in a pane header.
public struct RiftPaneHeaderAction: Identifiable {
	public var id: String
	public var symbolName: String
	public var label: String
	public var perform: () -> Void

	public init(id: String? = nil, symbolName: String, label: String, perform: @escaping () -> Void)
	{
		self.id = id ?? symbolName
		self.symbolName = symbolName
		self.label = label
		self.perform = perform
	}
}

final class RiftPaneHeaderView: RiftFlippedView, NSTextFieldDelegate {
	private let titleField = NSTextField(labelWithString: "")
	private let closeButton = NSButton()
	private let grip = RiftHeaderGripView()
	private var actionButtons: [RiftChromeIconButton] = []
	private var editor: NSTextField?
	private var renameCommit: ((String) -> Void)?
	/// When a click activated the window (a rename needs the window to have been key longer).
	private(set) var firstMouseTimestamp: TimeInterval?

	/// Buttons at the trailing edge, before any trailing inset.
	var actions: [RiftPaneHeaderAction] = [] {
		didSet {
			guard actions.map(\.id) != oldValue.map(\.id) else {
				zip(actionButtons, actions).forEach { $0.toolTip = $1.label }
				return
			}
			actionButtons.forEach { $0.removeFromSuperview() }
			actionButtons = actions.map { action in
				let button = RiftChromeIconButton()
				button.symbolName = action.symbolName
				button.symbolPointSize = 11
				button.toolTip = action.label
				button.setAccessibilityLabel(action.label)
				button.target = self
				button.action = #selector(actionClicked(_:))
				addSubview(button)
				return button
			}
			needsLayout = true
		}
	}
	/// The menu shown on a right-click in the header.
	var menuProvider: (() -> NSMenu?)?

	var title: String {
		get { titleField.stringValue }
		set {
			guard titleField.stringValue != newValue else { return }
			titleField.stringValue = newValue
			titleField.toolTip = newValue
		}
	}
	var showsCloseButton = true { didSet { updateVisibility() } }
	/// Show the grip for moving the pane (used when dragging the header moves the window).
	var showsGrip = false { didSet { updateVisibility() } }
	/// A bare header is an empty drag strip: no title or buttons.
	var isBare = false {
		didSet {
			updateVisibility()
			needsDisplay = true
		}
	}
	/// Space kept clear at the leading edge, for the window's buttons.
	var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { needsLayout = true } } }
	/// Room kept clear at the trailing edge (for example for a sidebar's toggle button).
	var trailingInset: CGFloat = 0 {
		didSet { if trailingInset != oldValue { needsLayout = true } }
	}
	var isFocused = false {
		didSet {
			titleField.textColor = isFocused ? .labelColor : .secondaryLabelColor
			needsDisplay = true
		}
	}
	var onMouseDown: ((NSEvent) -> Void)?
	/// Called when the pointer enters or leaves the header.
	var onPointerRegionChange: (() -> Void)?
	private var headerTrackingArea: NSTrackingArea?
	var onGripMouseDown: ((NSEvent) -> Void)? {
		get { grip.onMouseDown }
		set { grip.onMouseDown = newValue }
	}
	var onClose: (() -> Void)?

	private func updateVisibility() {
		titleField.isHidden = isBare
		closeButton.isHidden = isBare || !showsCloseButton
		grip.isHidden = isBare || !showsGrip
		needsLayout = true
	}

	override init(frame frameRect: NSRect) {
		super.init(frame: frameRect)
		titleField.font = .systemFont(ofSize: 11, weight: .medium)
		titleField.textColor = .secondaryLabelColor
		titleField.lineBreakMode = .byTruncatingTail
		titleField.alignment = .center
		addSubview(titleField)

		closeButton.image = NSImage(
			systemSymbolName: "xmark", accessibilityDescription: "Close Pane")
		closeButton.isBordered = false
		closeButton.imagePosition = .imageOnly
		closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
		closeButton.contentTintColor = .secondaryLabelColor
		closeButton.target = self
		closeButton.action = #selector(closeClicked)
		closeButton.setAccessibilityLabel("Close Pane")
		addSubview(closeButton)
		addSubview(grip)
		updateVisibility()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	@objc private func closeClicked() { onClose?() }

	@objc private func actionClicked(_ sender: RiftChromeIconButton) {
		guard let index = actionButtons.firstIndex(of: sender), actions.indices.contains(index)
		else { return }
		actions[index].perform()
	}

	override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

	/// Whether a window point falls on the title.
	func titleContains(windowPoint: CGPoint) -> Bool {
		!titleField.isHidden && titleField.frame.contains(convert(windowPoint, from: nil))
	}

	/// Edits the title in place; Return commits, Escape cancels.
	func beginRenaming(commit: @escaping (String) -> Void) {
		guard editor == nil else { return }
		let field = NSTextField(string: title)
		field.font = titleField.font
		field.alignment = titleField.alignment
		field.isBordered = false
		field.focusRingType = .none
		field.drawsBackground = true
		field.backgroundColor = .textBackgroundColor.withAlphaComponent(0.6)
		field.wantsLayer = true
		field.layer?.cornerRadius = 4
		field.delegate = self
		field.cell?.isScrollable = true
		field.frame = titleField.frame.insetBy(dx: -4, dy: -2)
		addSubview(field)
		editor = field
		renameCommit = commit
		titleField.isHidden = true
		window?.makeFirstResponder(field)
		field.currentEditor()?.selectAll(nil)
	}

	func controlTextDidEndEditing(_ notification: Notification) {
		guard let field = editor else { return }
		let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
		editor = nil
		field.removeFromSuperview()
		titleField.isHidden = isBare
		let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
		if movement != NSTextMovement.cancel.rawValue, !text.isEmpty, text != title {
			renameCommit?(text)
		}
		renameCommit = nil
	}

	func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
	{
		if selector == #selector(cancelOperation(_:)) {
			editor?.stringValue = title
			window?.makeFirstResponder(nil)
			return true
		}
		return false
	}

	override func layout() {
		super.layout()
		// A hidden header (the top strip is in use) is laid out when it is shown again.
		guard !isHidden else { return }
		let size: CGFloat = 16
		let y = ((bounds.height - size) / 2).rounded()
		var x = leadingInset + 6
		if !closeButton.isHidden {
			closeButton.frame = CGRect(x: x, y: y, width: size, height: size)
			x += size + 4
		}
		if !grip.isHidden {
			grip.frame = CGRect(x: x, y: y, width: size, height: size)
			x += size + 4
		}
		// Actions sit at the trailing edge: 20pt buttons, 2pt apart, 6pt in.
		var trailingX = bounds.width - trailingInset - 6
		for button in actionButtons.reversed() {
			trailingX -= 20
			button.frame = CGRect(
				x: trailingX, y: ((bounds.height - 20) / 2).rounded(), width: 20, height: 20)
			trailingX -= 2
		}
		let actionsRoom = bounds.width - trailingX
		// Keep the title centred in the header when there's room, clear of the leading controls.
		let side = max(28, x + 2, trailingInset + 8, actionsRoom + 4)
		let height = titleField.intrinsicContentSize.height
		let width = max(0, bounds.width - side * 2)
		let centred = CGRect(x: side, y: (bounds.height - height) / 2, width: width, height: height)
		if width >= min(titleField.intrinsicContentSize.width, 80) {
			titleField.frame = centred
		} else {
			titleField.frame = CGRect(
				x: x + 2, y: centred.minY, width: max(0, trailingX - x - 6),
				height: height)
		}
	}

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		needsLayout = true
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor.windowBackgroundColor.setFill()
		bounds.fill()
		if isFocused {
			NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
			bounds.fill(using: .sourceOver)
		}
		NSColor.separatorColor.setFill()
		CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
	}

	// Clicks on the title count as clicks on the header (so the title drags the pane).
	override func hitTest(_ point: NSPoint) -> NSView? {
		let hit = super.hitTest(point)
		return hit === titleField ? self : hit
	}

	override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
	override var mouseDownCanMoveWindow: Bool { false }
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		if let event, !(window?.isKeyWindow ?? false) { firstMouseTimestamp = event.timestamp }
		return true
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let headerTrackingArea { removeTrackingArea(headerTrackingArea) }
		let area = NSTrackingArea(
			rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
			owner: self, userInfo: nil)
		addTrackingArea(area)
		headerTrackingArea = area
	}

	override func mouseEntered(with event: NSEvent) { onPointerRegionChange?() }
	override func mouseExited(with event: NSEvent) { onPointerRegionChange?() }
}
