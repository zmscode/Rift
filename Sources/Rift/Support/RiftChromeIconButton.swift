import AppKit
import RiftCore

/// A chrome button like the sidebar's toggle: a borderless 13pt symbol in the foreground colour,
/// at 70% until the pointer is over it (or it is emphasized), 32% when disabled, with a round
/// hover background that fades in over 0.14s.
public final class RiftChromeIconButton: NSButton {
	public var symbolName = "sidebar.left" {
		didSet { if symbolName != oldValue { updateImage() } }
	}
	/// The symbol's point size.
	public var symbolPointSize: CGFloat = 13 {
		didSet { if symbolPointSize != oldValue { updateImage() } }
	}
	/// The symbol's opacity while the pointer is elsewhere.
	public var restingForegroundOpacity: CGFloat = 0.7 { didSet { updateAppearance() } }
	/// Draw the symbol at full opacity even when not hovered.
	public var isForegroundEmphasized = false { didSet { updateAppearance() } }
	public var foregroundColor: NSColor = .labelColor { didSet { updateAppearance() } }
	/// Show a background while hovered.
	public var showsHoverBackground = true { didSet { updateAppearance() } }
	/// The hover background; `nil` uses the foreground colour at 8% (dark) or 7.5% (light).
	public var hoverBackgroundColor: NSColor? { didSet { updateAppearance() } }
	/// Insets the hover background from the button's edges.
	public var backgroundInset: CGFloat = 0 { didSet { needsLayout = true } }
	/// Builds the menu shown on right-click (or Control-click); `nil` shows none.
	public var menuProvider: (() -> NSMenu?)?

	public override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

	private let hoverLayer = CALayer()
	private var trackingArea: NSTrackingArea?
	private var isHovered = false {
		didSet { if isHovered != oldValue { updateAppearance(animated: true) } }
	}

	public override init(frame: NSRect) {
		super.init(frame: frame)
		isBordered = false
		bezelStyle = .regularSquare
		imagePosition = .imageOnly
		imageScaling = .scaleNone
		wantsLayer = true
		layer?.cornerCurve = .continuous
		hoverLayer.cornerCurve = .continuous
		hoverLayer.zPosition = -1
		layer?.addSublayer(hoverLayer)
		updateImage()
	}

	@available(*, unavailable)
	public required init?(coder: NSCoder) { fatalError() }

	public override var isEnabled: Bool { didSet { updateAppearance() } }

	public override func layout() {
		super.layout()
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		let rect = bounds.insetBy(dx: backgroundInset, dy: backgroundInset)
		hoverLayer.frame = rect
		// A circle (or capsule) the size of the button.
		hoverLayer.cornerRadius = min(rect.width, rect.height) / 2
		layer?.cornerRadius = min(bounds.width, bounds.height) / 2
		CATransaction.commit()
	}

	public override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let trackingArea { removeTrackingArea(trackingArea) }
		let area = NSTrackingArea(
			rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
			owner: self)
		addTrackingArea(area)
		trackingArea = area
	}

	public override func mouseEntered(with event: NSEvent) { isHovered = true }
	public override func mouseExited(with event: NSEvent) { isHovered = false }
	public override var mouseDownCanMoveWindow: Bool { false }
	public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	public override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		updateAppearance()
	}

	private func updateImage() {
		let configuration = NSImage.SymbolConfiguration(
			pointSize: symbolPointSize, weight: .regular)
		image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
			.withSymbolConfiguration(configuration)
		updateAppearance()
	}

	private func updateAppearance(animated: Bool = false) {
		let opacity: CGFloat =
			isEnabled ? (isHovered || isForegroundEmphasized ? 1 : restingForegroundOpacity) : 0.32
		contentTintColor = foregroundColor.withAlphaComponent(opacity)
		let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
		var color: CGColor?
		if isHovered, isEnabled, showsHoverBackground {
			effectiveAppearance.performAsCurrentDrawingAppearance {
				color =
					(hoverBackgroundColor ?? foregroundColor.withAlphaComponent(dark ? 0.08 : 0.075))
					.cgColor
			}
		}
		let from = hoverLayer.presentation()?.backgroundColor ?? hoverLayer.backgroundColor
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		hoverLayer.removeAnimation(forKey: "rift.hover")
		hoverLayer.backgroundColor = color ?? NSColor.clear.cgColor
		CATransaction.commit()
		if animated {
			let fade = CABasicAnimation(keyPath: "backgroundColor")
			fade.fromValue = from ?? NSColor.clear.cgColor
			fade.toValue = color ?? NSColor.clear.cgColor
			fade.duration = 0.14
			hoverLayer.add(fade, forKey: "rift.hover")
		}
	}
}

/// A menu item that runs a closure.
final class RiftClosureMenuItem: NSMenuItem {
	private let handler: () -> Void

	init(title: String, handler: @escaping () -> Void) {
		self.handler = handler
		super.init(title: title, action: #selector(run), keyEquivalent: "")
		target = self
	}

	@available(*, unavailable)
	required init(coder: NSCoder) { fatalError() }

	@objc private func run() { handler() }
}
