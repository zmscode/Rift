import AppKit
import RiftCore

/// The strip tabs scroll in.
final class RiftTabClipView: NSView {
	override var isFlipped: Bool { true }
	override func hitTest(_ point: NSPoint) -> NSView? {
		let hit = super.hitTest(point)
		return hit === self ? nil : hit
	}
}

// MARK: - Tab item

/// What a tab item asks of the view it sits in (a bar or a sidebar list).
@MainActor
protocol RiftTabItemHost<TabID>: NSView {
	associatedtype TabID: Hashable
	var animation: RiftTabAnimation { get }
	func itemClicked(_ id: TabID)
	func itemClose(_ id: TabID)
	func itemRenamed(_ id: TabID, to title: String)
	func menu(for id: TabID) -> NSMenu
	func beginTabDrag(_ id: TabID, pointer: CGPoint)
	func moveTabDrag(_ id: TabID, pointer: CGPoint)
	func endTabDrag(_ id: TabID?, screenPoint: CGPoint?, cancelled: Bool)
}

@MainActor
final class RiftTabItemView<ID: Hashable>: NSView, NSTextFieldDelegate {
	let id: ID
	weak var bar: (any RiftTabItemHost<ID>)?
	/// Laid out as a sidebar row (no divider; sizes follow `scale`).
	var isVertical = false { didSet { if isVertical != oldValue { needsLayout = true } } }
	/// The sidebar text size over 13 (vertical rows): the title, close button and corners scale.
	var scale: CGFloat = 1 {
		didSet {
			guard scale != oldValue else { return }
			label.font = .systemFont(ofSize: 13 * scale, weight: .regular)
			needsLayout = true
		}
	}

	var title = "" {
		didSet {
			guard title != oldValue else { return }
			label.stringValue = title
			toolTip = title
			setAccessibilityLabel(title)
		}
	}
	var symbolName: String? {
		didSet {
			guard symbolName != oldValue else { return }
			icon.image = symbolName.flatMap {
				NSImage(systemSymbolName: $0, accessibilityDescription: nil)
			}?
			.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
			icon.isHidden = icon.image == nil
			needsLayout = true
		}
	}
	var isClosable = true { didSet { updateVisibility() } }
	/// Keeps the close button showing (the tab slid under the pointer after a close).
	var keepsCloseButtonShown = false {
		didSet { if keepsCloseButtonShown != oldValue { updateVisibility() } }
	}
	var isHovered = false {
		didSet { if isHovered != oldValue { updateVisibility(animated: true) } }
	}
	var isSelected = false {
		didSet {
			if isSelected != oldValue {
				updateVisibility()
				setAccessibilityValue(isSelected ? "selected" : nil)
			}
		}
	}
	var showsDivider = true {
		didSet {
			guard showsDivider != oldValue else { return }
			RiftTabAnimator.setOpacity(
				divider, showsDivider ? 1 : 0, timing: window == nil ? nil : animation.divider)
		}
	}
	private var animation: RiftTabAnimation { bar?.animation ?? .standard }

	private let hoverSurface = RiftSurfaceStackView()
	private let divider = CALayer()
	private let label = NSTextField(labelWithString: "")
	private let icon = NSImageView()
	private let fadeMask = CAGradientLayer()
	private let pulseLayer = CAShapeLayer()
	private var hoverRadius: CGFloat = 0
	/// Whether the title fade has been laid out once (it only animates in after that).
	private var didInitialTitleLayout = false
	private var titleIsFaded = false
	private let closeButton = RiftChromeIconButton()
	private var editor: NSTextField?
	private var density: RiftChromeDensity = .comfortable

	// Press tracking
	private var pressPoint: CGPoint?
	private var isDragging = false
	private var armsRename = false

	init(id: ID) {
		self.id = id
		super.init(frame: .zero)
		wantsLayer = true
		layer?.masksToBounds = false
		hoverSurface.alphaValue = 0
		addSubview(hoverSurface)
		divider.opacity = 1
		layer?.addSublayer(divider)
		label.lineBreakMode = .byClipping
		// Every tab's title: 13pt regular in the bar's foreground colour.
		label.font = .systemFont(ofSize: 13, weight: .regular)
		label.wantsLayer = true
		fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
		fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
		fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
		addSubview(label)
		icon.isHidden = true
		icon.imageScaling = .scaleProportionallyDown
		addSubview(icon)
		closeButton.symbolName = "xmark"
		closeButton.symbolPointSize = 10
		closeButton.restingForegroundOpacity = 0.7
		closeButton.target = self
		closeButton.action = #selector(closeClicked)
		closeButton.toolTip = "Close Tab"
		addSubview(closeButton)
		setAccessibilityElement(true)
		setAccessibilityRole(.radioButton)
		updateVisibility()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override var isFlipped: Bool { true }
	override var mouseDownCanMoveWindow: Bool { false }

	/// The whole tab takes clicks (its title and icon never swallow them); only the close button
	/// and the rename field answer for themselves.
	override func hitTest(_ point: NSPoint) -> NSView? {
		guard let hit = super.hitTest(point) else { return nil }
		if let editor, hit === editor || hit.isDescendant(of: editor) { return hit }
		if !closeButton.isHidden, hit === closeButton || hit.isDescendant(of: closeButton) {
			return hit
		}
		return self
	}

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		if let event, !(window?.isKeyWindow ?? false) { firstMouseTimestamp = event.timestamp }
		return true
	}
	private var firstMouseTimestamp: TimeInterval?

	func applyLooks(
		hover: RiftSurfaceStyle, density: RiftChromeDensity, textColor: NSColor, windowActive: Bool
	) {
		self.density = density
		hoverSurface.style = hover
		label.textColor = textColor
		icon.contentTintColor = textColor
		closeButton.foregroundColor = textColor
		// The separator colour at 18% (13.5% in background windows).
		effectiveAppearance.performAsCurrentDrawingAppearance {
			divider.backgroundColor =
				NSColor.separatorColor.withAlphaComponent(windowActive ? 0.18 : 0.135).cgColor
		}
		needsLayout = true
	}

	override func layout() {
		super.layout()
		let item = RiftTabItemLayout.resolve(
			size: bounds.size, density: density, showsCloseButton: showsCloseButton,
			hasIcon: !icon.isHidden, vertical: isVertical, scale: scale)
		divider.isHidden = isVertical
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		hoverSurface.frame = item.hoverFrame
		var style = hoverSurface.style
		style.cornerRadius = item.cornerRadius
		hoverSurface.style = style
		divider.frame = item.dividerFrame
		closeButton.frame = item.closeButtonFrame
		if let frame = item.iconFrame { icon.frame = frame }
		label.frame = item.titleFrame
		editor?.frame = item.titleFrame.insetBy(dx: -3, dy: -2)
		fadeMask.frame = label.bounds
		hoverRadius = item.cornerRadius
		CATransaction.commit()
		updateTitleFade()
	}

	/// A title that doesn't fit (within 4pt) fades over its last 20pt. The fade animates in on the
	/// title-clipping timing when it starts after the first layout.
	private func updateTitleFade() {
		guard label.bounds.width > 0 else { return }
		let start = RiftTabBarMath.titleFadeStart(
			titleWidth: label.attributedStringValue.size().width, fieldWidth: label.bounds.width)
		guard let start else {
			label.layer?.mask = nil
			titleIsFaded = false
			didInitialTitleLayout = true
			return
		}
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		fadeMask.frame = label.bounds
		fadeMask.locations = [0, NSNumber(value: Double(start)), 1]
		label.layer?.mask = fadeMask
		CATransaction.commit()
		if didInitialTitleLayout, !titleIsFaded {
			RiftTabAnimator.add(
				to: fadeMask, keyPath: "locations", from: [0, 1, 1] as [NSNumber],
				to: [0, NSNumber(value: Double(start)), 1], timing: animation.titleClipping)
		}
		titleIsFaded = true
		didInitialTitleLayout = true
	}

	/// Only while hovered (or kept showing by the bar).
	private var showsCloseButton: Bool { isClosable && (isHovered || keepsCloseButtonShown) }

	private func updateVisibility(animated: Bool = false) {
		closeButton.isHidden = !showsCloseButton
		let alpha: CGFloat = isHovered && !isSelected ? 1 : 0
		RiftTabAnimator.setAlpha(hoverSurface, alpha, timing: animated ? animation.hover : nil)
		needsLayout = true
	}

	/// The spring-loading flash on an unselected tab: its highlight flashes twice (clear, tint,
	/// clear, tint, clear at 0, ¼, ½, ¾ and 1, each step ease-in-out) over `duration`. The tint is
	/// white at 7% (dark) or black at 5% (light).
	func pulse(duration: TimeInterval) {
		guard !isSelected, let host = hoverSurface.layer else { return }
		if pulseLayer.superlayer !== host { host.addSublayer(pulseLayer) }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		pulseLayer.frame = hoverSurface.bounds
		pulseLayer.path = CGPath(
			roundedRect: pulseLayer.bounds, cornerWidth: hoverRadius, cornerHeight: hoverRadius,
			transform: nil)
		pulseLayer.fillColor = NSColor.clear.cgColor
		CATransaction.commit()
		let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		let tint =
			(dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.05))
			.cgColor
		let clear = NSColor.clear.cgColor
		let flash = CAKeyframeAnimation(keyPath: "fillColor")
		flash.values = [clear, tint, clear, tint, clear]
		flash.keyTimes = [0, 0.25, 0.5, 0.75, 1]
		flash.timingFunctions = Array(
			repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
		flash.duration = duration
		pulseLayer.add(flash, forKey: "rift.springLoad")
		// The hover surface is normally hidden on this tab; show it for the flash.
		hoverSurface.alphaValue = 1
		hoverSurface.layer?.sublayers?.forEach { if $0 !== pulseLayer { $0.opacity = 0 } }
		DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
			guard let self else { return }
			self.hoverSurface.layer?.sublayers?.forEach { $0.opacity = 1 }
			self.updateVisibility()
		}
	}

	@objc private func closeClicked() { bar?.itemClose(id) }

	override func menu(for event: NSEvent) -> NSMenu? { bar?.menu(for: id) }

	// MARK: Press, drag, rename

	override func mouseDown(with event: NSEvent) {
		guard editor == nil else { return super.mouseDown(with: event) }
		pressPoint = event.locationInWindow
		isDragging = false
		// A click on the already-selected tab in the key, active window renames it, unless it
		// comes within a double-click interval of the click that activated the window.
		let sinceFirstMouse = firstMouseTimestamp.map { event.timestamp - $0 } ?? .infinity
		armsRename =
			isSelected && event.clickCount == 1 && (window?.isKeyWindow ?? false)
			&& NSApp.isActive && sinceFirstMouse > NSEvent.doubleClickInterval
		if !isSelected { bar?.itemClicked(id) }
	}

	override func mouseDragged(with event: NSEvent) {
		guard let pressPoint, let bar else { return }
		let point = event.locationInWindow
		if !isDragging {
			guard
				hypot(point.x - pressPoint.x, point.y - pressPoint.y) > RiftTabBarMath.dragThreshold
			else { return }
			isDragging = true
			armsRename = false
			bar.beginTabDrag(id, pointer: pressPoint)
		}
		bar.moveTabDrag(id, pointer: point)
	}

	override func mouseUp(with event: NSEvent) {
		defer { pressPoint = nil }
		if isDragging {
			isDragging = false
			let screen = window?.convertPoint(toScreen: event.locationInWindow)
			bar?.endTabDrag(id, screenPoint: screen, cancelled: false)
			return
		}
		if armsRename, event.clickCount == 1 {
			armsRename = false
			beginRenaming()
		}
	}

	func beginRenaming() {
		guard editor == nil else { return }
		let field = NSTextField(string: title)
		field.font = label.font
		field.isBordered = false
		field.focusRingType = .none
		field.drawsBackground = true
		field.backgroundColor = .textBackgroundColor.withAlphaComponent(0.6)
		field.wantsLayer = true
		field.layer?.cornerRadius = 4
		field.delegate = self
		field.cell?.isScrollable = true
		addSubview(field)
		editor = field
		label.isHidden = true
		needsLayout = true
		layoutSubtreeIfNeeded()
		window?.makeFirstResponder(field)
		field.currentEditor()?.selectAll(nil)
	}

	func controlTextDidEndEditing(_ notification: Notification) {
		guard let field = editor else { return }
		let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
		let cancelled = movement == NSTextMovement.cancel.rawValue
		editor = nil
		field.removeFromSuperview()
		label.isHidden = false
		if !cancelled { bar?.itemRenamed(id, to: field.stringValue) }
	}

	func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool
	{
		if selector == #selector(cancelOperation(_:)) {
			editor?.stringValue = title
			window?.makeFirstResponder(bar)
			return true
		}
		return false
	}
}
