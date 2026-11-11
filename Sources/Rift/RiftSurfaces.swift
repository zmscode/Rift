import AppKit
import RiftCore

// MARK: - Extension point

/// What a pane surface is showing for.
public struct RiftPaneSurfaceState: Equatable, Sendable {
	public var isFocused: Bool
	public var isWindowActive: Bool
	public var isDark: Bool

	public init(isFocused: Bool, isWindowActive: Bool, isDark: Bool) {
		self.isFocused = isFocused
		self.isWindowActive = isWindowActive
		self.isDark = isDark
	}
}

/// Supplies the view drawn behind each pane's content (its "surface": background, glass, fills,
/// strokes, shadows), and how opaque the content is in each state.
///
/// Rift draws no pane background of its own. Set `RiftConfiguration.paneSurface` to a provider,
/// such as `RiftPaneSurfaces`, or your own type.
public protocol RiftPaneSurfaceProviding {
	/// A new surface view for one pane. It is sized to the pane and sits behind the content.
	@MainActor func makeSurfaceView() -> NSView
	/// Brings `view` (made by `makeSurfaceView()`) up to date for `state`.
	@MainActor func update(_ view: NSView, for state: RiftPaneSurfaceState)
	/// Opacity of the pane's content in `state`, or `nil` to use the configuration's alphas.
	@MainActor func contentOpacity(for state: RiftPaneSurfaceState) -> CGFloat?
}

// MARK: - Built-in surface styles

/// A colour layer.
public struct RiftSurfaceFill: Equatable, Sendable {
	public var color: NSColor
	public var blendMode: RiftDividerBlendMode

	public init(color: NSColor, blendMode: RiftDividerBlendMode = .normal) {
		self.color = color
		self.blendMode = blendMode
	}
}

/// A glass layer. Liquid glass on macOS 26 and later; a visual-effect material before that.
public struct RiftSurfaceGlass: Equatable, Sendable {
	public enum Style: Sendable, Equatable { case regular, clear }
	public var style: Style
	public var tint: NSColor?
	/// Material used where liquid glass isn't available.
	public var fallbackMaterial: NSVisualEffectView.Material

	public init(
		style: Style = .regular, tint: NSColor? = nil,
		fallbackMaterial: NSVisualEffectView.Material = .hudWindow
	) {
		self.style = style
		self.tint = tint
		self.fallbackMaterial = fallbackMaterial
	}
}

/// An outline drawn along the surface's edge.
public struct RiftSurfaceStroke: Equatable, Sendable {
	public var color: NSColor
	public var width: CGFloat
	public var blendMode: RiftDividerBlendMode

	public init(color: NSColor, width: CGFloat = 1, blendMode: RiftDividerBlendMode = .normal) {
		self.color = color
		self.width = width
		self.blendMode = blendMode
	}
}

/// A drop shadow cast by the surface.
public struct RiftSurfaceShadow: Equatable, Sendable {
	public var color: NSColor
	public var opacity: Float
	public var radius: CGFloat
	public var offset: CGSize

	public init(color: NSColor = .black, opacity: Float, radius: CGFloat, offset: CGSize = .zero) {
		self.color = color
		self.opacity = opacity
		self.radius = radius
		self.offset = offset
	}
}

/// One surface look, layered back to front: shadows, backdrop, glass, fill, second fill, strokes.
public struct RiftSurfaceStyle: Equatable, Sendable {
	public var cornerRadius: CGFloat = 0
	/// Opacity of the pane's content over this surface.
	public var contentOpacity: CGFloat = 1
	public var shadows: [RiftSurfaceShadow] = []
	public var backdrop: RiftSurfaceFill?
	public var glass: RiftSurfaceGlass?
	public var fill: RiftSurfaceFill?
	public var secondFill: RiftSurfaceFill?
	public var strokes: [RiftSurfaceStroke] = []

	public init() {}
}

/// Surface looks for every pane state, for light and dark appearance.
///
/// Each state is a complete style. `RiftPaneSurfaces.modern(_:)` builds them as a cascade: the focused pane starts from the pane style, and inactive-window
/// styles start from the active-window ones.
public struct RiftPaneSurfaces: Equatable, Sendable, RiftPaneSurfaceProviding {
	public struct States: Equatable, Sendable {
		public var pane: RiftSurfaceStyle
		public var focusedPane: RiftSurfaceStyle
		public var inactiveWindowPane: RiftSurfaceStyle
		public var inactiveWindowFocusedPane: RiftSurfaceStyle

		public init(
			pane: RiftSurfaceStyle, focusedPane: RiftSurfaceStyle,
			inactiveWindowPane: RiftSurfaceStyle, inactiveWindowFocusedPane: RiftSurfaceStyle
		) {
			self.pane = pane
			self.focusedPane = focusedPane
			self.inactiveWindowPane = inactiveWindowPane
			self.inactiveWindowFocusedPane = inactiveWindowFocusedPane
		}

		public func style(focused: Bool, windowActive: Bool) -> RiftSurfaceStyle {
			switch (focused, windowActive) {
			case (false, true): pane
			case (true, true): focusedPane
			case (false, false): inactiveWindowPane
			case (true, false): inactiveWindowFocusedPane
			}
		}
	}

	public var light: States
	public var dark: States

	public init(light: States, dark: States) {
		self.light = light
		self.dark = dark
	}

	public func style(for state: RiftPaneSurfaceState) -> RiftSurfaceStyle {
		(state.isDark ? dark : light).style(
			focused: state.isFocused, windowActive: state.isWindowActive)
	}

	@MainActor public func makeSurfaceView() -> NSView { RiftSurfaceStackView() }

	@MainActor public func update(_ view: NSView, for state: RiftPaneSurfaceState) {
		(view as? RiftSurfaceStackView)?.style = style(for: state)
	}

	@MainActor public func contentOpacity(for state: RiftPaneSurfaceState) -> CGFloat? {
		style(for: state).contentOpacity
	}

	/// Density of the Modern look.
	public enum Density: Sendable { case comfortable, compact }

	/// The built-in "modern" look.
	///
	/// Comfortable: separate glass cards, 10pt corners, a tinted glass layer, a light fill and
	/// (dark) an overlay backdrop; unfocused content at 0.7, background windows at 0.5 with the
	/// focused pane at 0.8 (dark) or 0.85 (light). Compact: touching panes with no card
	/// surface, and the same content opacities (0.6 for unfocused panes in light background windows).
	public static func modern(_ density: Density) -> RiftPaneSurfaces {
		func rgb(_ v: CGFloat, _ a: CGFloat) -> NSColor {
			NSColor(srgbRed: v, green: v, blue: v, alpha: a)
		}
		let canvas: CGFloat = 0.117647
		switch density {
		case .comfortable:
			var darkPane = RiftSurfaceStyle()
			darkPane.cornerRadius = 10
			darkPane.contentOpacity = 0.7
			darkPane.backdrop = RiftSurfaceFill(color: rgb(canvas, 0.48), blendMode: .overlay)
			darkPane.glass = RiftSurfaceGlass(tint: rgb(canvas, 0.3))
			darkPane.fill = RiftSurfaceFill(color: rgb(0, 0.15))
			var darkFocused = darkPane
			darkFocused.contentOpacity = 1
			darkFocused.fill = RiftSurfaceFill(color: rgb(0, 0))
			var darkInactive = darkPane
			darkInactive.contentOpacity = 0.5
			darkInactive.backdrop = RiftSurfaceFill(color: rgb(0, 0.5))
			var darkInactiveFocused = darkFocused
			darkInactiveFocused.contentOpacity = 0.8
			darkInactiveFocused.backdrop = darkInactive.backdrop
			darkInactiveFocused.fill = RiftSurfaceFill(color: rgb(1, 0.02))

			var lightPane = RiftSurfaceStyle()
			lightPane.cornerRadius = 10
			lightPane.contentOpacity = 0.7
			lightPane.glass = RiftSurfaceGlass(tint: rgb(canvas, 0.25))
			lightPane.fill = RiftSurfaceFill(color: rgb(0, 0.05), blendMode: .plusDarker)
			var lightFocused = lightPane
			lightFocused.contentOpacity = 1
			lightFocused.fill = RiftSurfaceFill(color: rgb(1, 0.3), blendMode: .overlay)
			var lightInactive = lightPane
			lightInactive.contentOpacity = 0.5
			var lightInactiveFocused = lightFocused
			lightInactiveFocused.contentOpacity = 0.85
			return RiftPaneSurfaces(
				light: States(
					pane: lightPane, focusedPane: lightFocused, inactiveWindowPane: lightInactive,
					inactiveWindowFocusedPane: lightInactiveFocused),
				dark: States(
					pane: darkPane, focusedPane: darkFocused, inactiveWindowPane: darkInactive,
					inactiveWindowFocusedPane: darkInactiveFocused))
		case .compact:
			func opacity(_ value: CGFloat) -> RiftSurfaceStyle {
				var style = RiftSurfaceStyle()
				style.contentOpacity = value
				return style
			}
			return RiftPaneSurfaces(
				light: States(
					pane: opacity(0.7), focusedPane: opacity(1), inactiveWindowPane: opacity(0.6),
					inactiveWindowFocusedPane: opacity(0.85)),
				dark: States(
					pane: opacity(0.7), focusedPane: opacity(1), inactiveWindowPane: opacity(0.5),
					inactiveWindowFocusedPane: opacity(0.8)))
		}
	}
}

// MARK: - Surface stack view

/// A layer-backed plane in the surface stack.
final class RiftSurfacePlane: NSView {
	override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
	}
	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }
	override var isFlipped: Bool { true }
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Draws a `RiftSurfaceStyle`. Planes, back to front: shadows, backdrop, glass, fill, second fill,
/// strokes.
public final class RiftSurfaceStackView: NSView {
	public var style = RiftSurfaceStyle() { didSet { if style != oldValue { apply() } } }

	private let shadowPlane = RiftSurfacePlane()
	private let backdropPlane = RiftSurfacePlane()
	private var glassView: NSView?
	private var glassTintLayer: CALayer?
	private let fillPlane = RiftSurfacePlane()
	private let secondFillPlane = RiftSurfacePlane()
	private let strokePlane = RiftSurfacePlane()
	private var strokeLayers: [CAShapeLayer] = []
	private var shadowLayers: [CALayer] = []
	private var appliedGlass: RiftSurfaceGlass?

	public override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		for plane in [shadowPlane, backdropPlane, fillPlane, secondFillPlane, strokePlane] {
			plane.autoresizingMask = [.width, .height]
			addSubview(plane)
		}
		apply()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	public override var isFlipped: Bool { true }
	public override func hitTest(_ point: NSPoint) -> NSView? { nil }

	public override func layout() {
		super.layout()
		frameLayers()
	}

	public override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		apply()
	}

	private func cgColor(_ color: NSColor?) -> CGColor? {
		guard let color else { return nil }
		var result: CGColor?
		effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
		return result
	}

	private func apply() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }
		for (plane, fill) in [
			(backdropPlane, style.backdrop), (fillPlane, style.fill),
			(secondFillPlane, style.secondFill),
		] {
			plane.isHidden = fill == nil
			plane.layer?.backgroundColor = cgColor(fill?.color)
			plane.layer?.compositingFilter = fill?.blendMode.compositingFilter
			plane.layer?.cornerCurve = .continuous
		}
		applyGlass()
		applyShadows()
		applyStrokes()
		frameLayers()
	}

	private func applyGlass() {
		guard style.glass != appliedGlass else { return }
		appliedGlass = style.glass
		glassView?.removeFromSuperview()
		glassView = nil
		glassTintLayer = nil
		guard let glass = style.glass else { return }
		let view: NSView
		if #available(macOS 26.0, *) {
			let effect = NSGlassEffectView(frame: bounds)
			effect.style = glass.style == .clear ? .clear : .regular
			effect.tintColor = glass.tint
			view = effect
		} else {
			let effect = NSVisualEffectView(frame: bounds)
			effect.material = glass.fallbackMaterial
			effect.blendingMode = .behindWindow
			effect.state = .followsWindowActiveState
			effect.wantsLayer = true
			effect.layer?.masksToBounds = true
			let tint = CALayer()
			tint.backgroundColor = cgColor(glass.tint)
			effect.layer?.addSublayer(tint)
			glassTintLayer = tint
			view = effect
		}
		view.autoresizingMask = [.width, .height]
		// Glass sits above the backdrop and below the fills.
		addSubview(view, positioned: .above, relativeTo: backdropPlane)
		glassView = view
	}

	private func applyShadows() {
		shadowLayers.forEach { $0.removeFromSuperlayer() }
		shadowLayers = style.shadows.map { shadow in
			let layer = CALayer()
			layer.shadowColor = cgColor(shadow.color)
			layer.shadowOpacity = shadow.opacity
			layer.shadowRadius = shadow.radius
			layer.shadowOffset = shadow.offset
			shadowPlane.layer?.addSublayer(layer)
			return layer
		}
	}

	private func applyStrokes() {
		while strokeLayers.count < style.strokes.count {
			let stroke = CAShapeLayer()
			stroke.fillColor = nil
			strokePlane.layer?.addSublayer(stroke)
			strokeLayers.append(stroke)
		}
		while strokeLayers.count > style.strokes.count {
			strokeLayers.removeLast().removeFromSuperlayer()
		}
		for (layer, stroke) in zip(strokeLayers, style.strokes) {
			layer.strokeColor = cgColor(stroke.color)
			layer.lineWidth = stroke.width
			layer.compositingFilter = stroke.blendMode.compositingFilter
		}
	}

	private func frameLayers() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }
		let rect = bounds
		let radius = min(style.cornerRadius, min(rect.width, rect.height) / 2)
		for plane in [backdropPlane, fillPlane, secondFillPlane] {
			plane.layer?.cornerRadius = radius
		}
		glassTintLayer?.frame = rect
		if #available(macOS 26.0, *), let effect = glassView as? NSGlassEffectView {
			effect.cornerRadius = radius
		} else {
			glassView?.layer?.cornerRadius = radius
		}
		let path = CGPath(
			roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
		for shadow in shadowLayers {
			shadow.frame = rect
			shadow.shadowPath = path
		}
		for (layer, stroke) in zip(strokeLayers, style.strokes) {
			let inset = rect.insetBy(dx: stroke.width / 2, dy: stroke.width / 2)
			let r = max(0, radius - stroke.width / 2)
			layer.frame = rect
			layer.path = CGPath(roundedRect: inset, cornerWidth: r, cornerHeight: r, transform: nil)
		}
	}
}
