import AppKit
import RiftCore

/// A shadow drawn around a glass pane.
public struct RiftPaneShadow {
	public var color: NSColor
	public var opacity: Double
	public var radius: CGFloat
	public var offset: CGSize

	public init(color: NSColor = .black, opacity: Double, radius: CGFloat, offset: CGSize = .zero) {
		self.color = color
		self.opacity = opacity
		self.radius = radius
		self.offset = offset
	}
}

/// Liquid glass behind panes.
///
/// On macOS 26 and later each pane sits on an `NSGlassEffectView`, and all of them live in one
/// `NSGlassEffectContainerView`, so neighbouring panes can merge. Earlier systems get an
/// `NSVisualEffectView` (`.popover` material, within-window blending, always active) instead.
/// Pane content has to be at least partly transparent for the glass to show.
public struct RiftGlassConfiguration {
	public enum Style: Sendable, Equatable {
		case regular
		case clear
	}

	public var isEnabled = false
	public var style: Style = .regular
	public var tintColor: NSColor?
	public var cornerRadius: CGFloat = 0
	/// Line drawn around each glass pane (`nil` or a width of 0 draws none).
	public var outerRimColor: NSColor?
	public var outerRimWidth: CGFloat = 0
	public var shadows: [RiftPaneShadow] = []
	/// How strongly touching panes merge, 0…1. Panes only merge when there is no visible gap
	/// between them (`metrics.dividerThickness <= 0`).
	public var mergeFactor: CGFloat = 1

	public init() {}

	/// The container spacing for a given gap between panes: 2 when panes touch, else 0, scaled by
	/// `mergeFactor` (clamped to 0…1).
	public func mergeSpacing(forGap gap: CGFloat) -> CGFloat {
		let base: CGFloat = gap <= 0 ? 2 : 0
		return base * min(max(mergeFactor, 0), 1)
	}
}

/// The glass behind one pane: the effect view, an outer rim and shadows.
final class RiftPaneGlassView: NSView {
	private let effectView: NSView
	private let rimLayer = CAShapeLayer()
	private let shadowContainer = CALayer()
	private let shadowPunchOut = CAShapeLayer()
	private var shadowLayers: [CALayer] = []
	private var configuration = RiftGlassConfiguration()

	override init(frame frameRect: NSRect) {
		if #available(macOS 26.0, *) {
			effectView = NSGlassEffectView()
		} else {
			let visual = NSVisualEffectView()
			visual.material = .popover
			visual.blendingMode = .withinWindow
			visual.state = .active
			visual.wantsLayer = true
			effectView = visual
		}
		super.init(frame: frameRect)
		wantsLayer = true
		layer?.masksToBounds = false
		effectView.autoresizingMask = [.width, .height]
		effectView.frame = bounds
		addSubview(effectView)
		shadowContainer.mask = shadowPunchOut
		layer?.insertSublayer(shadowContainer, at: 0)
		rimLayer.fillColor = nil
		layer?.addSublayer(rimLayer)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	func apply(_ configuration: RiftGlassConfiguration) {
		self.configuration = configuration
		if #available(macOS 26.0, *), let glass = effectView as? NSGlassEffectView {
			glass.style = configuration.style == .clear ? .clear : .regular
			glass.tintColor = configuration.tintColor
			glass.cornerRadius = configuration.cornerRadius
		} else {
			effectView.layer?.cornerRadius = configuration.cornerRadius
			effectView.layer?.masksToBounds = configuration.cornerRadius > 0
		}
		updateShadowLayers()
		updatePaths()
	}

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		updatePaths()
	}

	private func updateShadowLayers() {
		shadowLayers.forEach { $0.removeFromSuperlayer() }
		shadowLayers = configuration.shadows.map { shadow in
			let layer = CALayer()
			layer.shadowColor = shadow.color.cgColor
			layer.shadowOpacity = Float(shadow.opacity)
			layer.shadowRadius = shadow.radius
			layer.shadowOffset = shadow.offset
			shadowContainer.addSublayer(layer)
			return layer
		}
	}

	private func updatePaths() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }
		let radius = configuration.cornerRadius
		let shape = CGPath(
			roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
		// Shadows only show outside the pane, so they never darken the glass itself.
		let reach =
			(configuration.shadows.map {
				$0.radius * 2 + max(abs($0.offset.width), abs($0.offset.height))
			}.max() ?? 0) + 1
		shadowContainer.frame = bounds
		let punchOut = CGMutablePath()
		punchOut.addRect(bounds.insetBy(dx: -reach, dy: -reach))
		punchOut.addPath(shape)
		shadowPunchOut.path = punchOut
		shadowPunchOut.fillRule = .evenOdd
		for layer in shadowLayers {
			layer.frame = bounds
			layer.shadowPath = shape
		}
		let width = configuration.outerRimWidth
		if let color = configuration.outerRimColor, width > 0 {
			let inset = bounds.insetBy(dx: width / 2, dy: width / 2)
			let rimRadius = max(0, radius - width / 2)
			rimLayer.path = CGPath(
				roundedRect: inset, cornerWidth: rimRadius, cornerHeight: rimRadius, transform: nil)
			rimLayer.strokeColor = color.cgColor
			rimLayer.lineWidth = width
			rimLayer.isHidden = false
		} else {
			rimLayer.isHidden = true
		}
	}
}

/// Holds the glass container and one glass view per pane, behind all pane content.
@MainActor
final class RiftGlassController {
	let containerView: NSView
	private let contentView = RiftFlippedView()
	private var paneViews: [AnyHashable: RiftPaneGlassView] = [:]
	private(set) var configuration = RiftGlassConfiguration()

	init() {
		if #available(macOS 26.0, *) {
			let container = NSGlassEffectContainerView()
			container.contentView = contentView
			containerView = container
		} else {
			let plain = NSView()
			contentView.autoresizingMask = [.width, .height]
			plain.addSubview(contentView)
			containerView = plain
		}
		containerView.wantsLayer = true
		contentView.wantsLayer = true
	}

	func apply(_ configuration: RiftGlassConfiguration, gap: CGFloat) {
		self.configuration = configuration
		if #available(macOS 26.0, *), let container = containerView as? NSGlassEffectContainerView {
			container.spacing = configuration.mergeSpacing(forGap: gap)
		}
		paneViews.values.forEach { $0.apply(configuration) }
	}

	/// Matches the glass views to `frames` (in the container's coordinates).
	func place(_ frames: [AnyHashable: CGRect], animated: Bool) {
		for (id, view) in paneViews where frames[id] == nil {
			view.removeFromSuperview()
			paneViews[id] = nil
		}
		for (id, frame) in frames {
			if let view = paneViews[id] {
				if animated { view.animator().frame = frame } else { view.frame = frame }
			} else {
				let view = RiftPaneGlassView(frame: frame)
				view.apply(configuration)
				contentView.addSubview(view)
				paneViews[id] = view
			}
		}
	}
}
