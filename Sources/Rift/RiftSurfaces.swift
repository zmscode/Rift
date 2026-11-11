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

/// A pane surface provider, comparable so configurations can be compared.
public struct RiftPaneSurface: Equatable {
	public let provider: any RiftPaneSurfaceProviding
	private let identity: AnyHashable

	/// The built-in layered surface.
	public init(_ surfaces: RiftPaneSurfaces) {
		provider = surfaces
		identity = AnyHashable(surfaces)
	}

	/// Your own provider. Two values are equal when they hold the same object.
	public init<Provider: RiftPaneSurfaceProviding & AnyObject>(custom provider: Provider) {
		self.provider = provider
		identity = AnyHashable(ObjectIdentifier(provider))
	}

	public static func == (lhs: RiftPaneSurface, rhs: RiftPaneSurface) -> Bool {
		lhs.identity == rhs.identity
	}
}

// MARK: - Built-in surface styles

/// A colour layer.
public struct RiftSurfaceFill: Hashable, Sendable {
	public var color: NSColor
	public var blendMode: RiftDividerBlendMode
	/// The theme role this colour stands for. A themed surface takes the role's colour at this
	/// colour's alpha; without a theme (or a role) `color` is drawn as it is.
	public var role: RiftColorRole?

	public init(color: NSColor, blendMode: RiftDividerBlendMode = .normal, role: RiftColorRole? = nil) {
		self.color = color
		self.blendMode = blendMode
		self.role = role
	}
}

/// A glass layer. Liquid glass on macOS 26 and later; a visual-effect material before that.
public struct RiftSurfaceGlass: Hashable, Sendable {
	public enum Style: Sendable, Hashable { case regular, clear }
	public var style: Style
	public var tint: NSColor?
	/// The theme role the tint stands for (see `RiftSurfaceFill.role`).
	public var tintRole: RiftColorRole?
	/// Material used where liquid glass isn't available.
	public var fallbackMaterial: NSVisualEffectView.Material

	public init(
		style: Style = .regular, tint: NSColor? = nil, tintRole: RiftColorRole? = nil,
		fallbackMaterial: NSVisualEffectView.Material = .hudWindow
	) {
		self.style = style
		self.tint = tint
		self.tintRole = tintRole
		self.fallbackMaterial = fallbackMaterial
	}
}

/// An outline drawn along the surface's edge.
public struct RiftSurfaceStroke: Hashable, Sendable {
	public var color: NSColor
	public var width: CGFloat
	public var blendMode: RiftDividerBlendMode
	/// The theme role this colour stands for (see `RiftSurfaceFill.role`).
	public var role: RiftColorRole?

	public init(
		color: NSColor, width: CGFloat = 1, blendMode: RiftDividerBlendMode = .normal,
		role: RiftColorRole? = nil
	) {
		self.color = color
		self.width = width
		self.blendMode = blendMode
		self.role = role
	}
}

/// A drop shadow cast by the surface.
public struct RiftSurfaceShadow: Hashable, Sendable {
	public var color: NSColor
	public var opacity: Float
	public var radius: CGFloat
	public var offset: CGSize
	/// The theme role this colour stands for (see `RiftSurfaceFill.role`).
	public var role: RiftColorRole?

	public init(
		color: NSColor = .black, opacity: Float, radius: CGFloat, offset: CGSize = .zero,
		role: RiftColorRole? = nil
	) {
		self.role = role
		self.color = color
		self.opacity = opacity
		self.radius = radius
		self.offset = offset
	}
}

/// One surface look, layered back to front: shadows, backdrop, glass, fill, second fill, strokes.
public struct RiftSurfaceStyle: Hashable, Sendable {
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
public struct RiftPaneSurfaces: Hashable, Sendable, RiftPaneSurfaceProviding {
	public struct States: Hashable, Sendable {
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
			darkPane.backdrop = RiftSurfaceFill(
				color: rgb(canvas, 0.48), blendMode: .overlay, role: .canvas)
			darkPane.glass = RiftSurfaceGlass(tint: rgb(canvas, 0.3), tintRole: .canvas)
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
			lightPane.glass = RiftSurfaceGlass(tint: rgb(canvas, 0.25), tintRole: .canvas)
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
			// Touching panes. Dark: the focused pane gets a faint white backdrop. Light: panes get a
			// near-white plus-darker fill and the focused pane a grey one. Background windows keep
			// the same looks with lower content opacity.
			var darkPane = RiftSurfaceStyle()
			darkPane.contentOpacity = 0.7
			var darkFocused = darkPane
			darkFocused.contentOpacity = 1
			darkFocused.backdrop = RiftSurfaceFill(color: rgb(1, 0.03))
			var darkInactive = darkPane
			darkInactive.contentOpacity = 0.5
			var darkInactiveFocused = darkFocused
			darkInactiveFocused.contentOpacity = 0.8

			var lightPane = RiftSurfaceStyle()
			lightPane.contentOpacity = 0.7
			lightPane.fill = RiftSurfaceFill(
				color: rgb(0.964706, 0.8), blendMode: .plusDarker, role: .surfaceRaised)
			var lightFocused = lightPane
			lightFocused.contentOpacity = 1
			lightFocused.fill = RiftSurfaceFill(color: rgb(0.156863, 0.3))
			var lightInactive = lightPane
			lightInactive.contentOpacity = 0.6
			var lightInactiveFocused = lightFocused
			lightInactiveFocused.contentOpacity = 0.85
			return RiftPaneSurfaces(
				light: States(
					pane: lightPane, focusedPane: lightFocused, inactiveWindowPane: lightInactive,
					inactiveWindowFocusedPane: lightInactiveFocused),
				dark: States(
					pane: darkPane, focusedPane: darkFocused, inactiveWindowPane: darkInactive,
					inactiveWindowFocusedPane: darkInactiveFocused))
		}
	}
}

// MARK: - Window surface

/// The surface behind the whole layout: a window material with a tint and a backdrop, and a soft
/// inner shadow along the window's edge.
public struct RiftWindowSurface: Hashable, Sendable {
	public struct Look: Hashable, Sendable {
		/// The material shown behind the window.
		public var material: NSVisualEffectView.Material?
		public var tint: NSColor?
		/// The theme role the tint stands for (see `RiftSurfaceFill.role`).
		public var tintRole: RiftColorRole?
		public var backdrop: RiftSurfaceFill?

		public init(
			material: NSVisualEffectView.Material? = .hudWindow, tint: NSColor? = nil,
			tintRole: RiftColorRole? = nil, backdrop: RiftSurfaceFill? = nil
		) {
			self.material = material
			self.tint = tint
			self.tintRole = tintRole
			self.backdrop = backdrop
		}
	}

	/// A shadow cast inward from the window's edge. Only the shadow is drawn ("knockout").
	public struct InnerShadow: Hashable, Sendable {
		public var color: NSColor
		public var opacity: Float
		public var blurRadius: CGFloat
		/// Positive y moves the shadow down.
		public var offset: CGSize
		public var blendMode: RiftDividerBlendMode
		/// The shadow's corner radius; `nil` follows the window's corners.
		public var cornerRadius: CGFloat?

		public init(
			color: NSColor, opacity: Float = 1, blurRadius: CGFloat, offset: CGSize,
			blendMode: RiftDividerBlendMode = .normal, cornerRadius: CGFloat? = nil
		) {
			self.color = color
			self.opacity = opacity
			self.blurRadius = blurRadius
			self.offset = offset
			self.blendMode = blendMode
			self.cornerRadius = cornerRadius
		}
	}

	public var cornerRadius: CGFloat
	public var light: Look
	public var dark: Look
	public var inactiveWindowLight: Look
	public var inactiveWindowDark: Look
	public var lightInnerShadow: InnerShadow?
	public var darkInnerShadow: InnerShadow?

	public init(
		cornerRadius: CGFloat = 12, light: Look, dark: Look, inactiveWindowLight: Look? = nil,
		inactiveWindowDark: Look? = nil, lightInnerShadow: InnerShadow? = nil,
		darkInnerShadow: InnerShadow? = nil
	) {
		self.cornerRadius = cornerRadius
		self.light = light
		self.dark = dark
		self.inactiveWindowLight = inactiveWindowLight ?? light
		self.inactiveWindowDark = inactiveWindowDark ?? dark
		self.lightInnerShadow = lightInnerShadow
		self.darkInnerShadow = darkInnerShadow
	}

	public func look(isDark: Bool, isWindowActive: Bool) -> Look {
		switch (isDark, isWindowActive) {
		case (true, true): dark
		case (true, false): inactiveWindowDark
		case (false, true): light
		case (false, false): inactiveWindowLight
		}
	}

	/// The built-in "modern" window: the HUD material with a dark grey tint (α 0.5) and a black
	/// overlay backdrop (α 0.6) in dark mode; a white (compact) or grey (comfortable) tint at α 0.7
	/// in light mode; 12pt corners. In background windows, comfortable dark tints white at α 0.5.
	/// Inner shadow: dark, white α 0.6 overlay, blur 2.5, 1.5pt down; light, white plus-lighter at
	/// opacity 0.15, blur 1, 0.5pt down, 16pt corners.
	public static func modern(_ density: RiftPaneSurfaces.Density) -> RiftWindowSurface {
		func rgb(_ v: CGFloat, _ a: CGFloat) -> NSColor {
			NSColor(srgbRed: v, green: v, blue: v, alpha: a)
		}
		let canvas: CGFloat = 0.117647
		let dark = Look(
			tint: rgb(canvas, 0.5), tintRole: .canvas,
			backdrop: RiftSurfaceFill(color: rgb(0, 0.6), blendMode: .overlay))
		var inactiveDark = dark
		if density == .comfortable { inactiveDark.tint = rgb(1, 0.5) }
		// Compact light takes the system's canvas, not the theme's.
		let light = density == .compact
			? Look(tint: rgb(1, 0.7)) : Look(tint: rgb(canvas, 0.7), tintRole: .canvas)
		return RiftWindowSurface(
			cornerRadius: 12, light: light, dark: dark, inactiveWindowDark: inactiveDark,
			lightInnerShadow: InnerShadow(
				color: rgb(1, 1), opacity: 0.15, blurRadius: 1,
				offset: CGSize(width: 0, height: 0.5),
				blendMode: .plusLighter, cornerRadius: 16),
			darkInnerShadow: InnerShadow(
				color: rgb(1, 0.6), blurRadius: 2.5, offset: CGSize(width: 0, height: 1.5),
				blendMode: .overlay))
	}
}

/// Draws a `RiftWindowSurface` behind the panes.
final class RiftWindowSurfaceView: NSView {
	var surface: RiftWindowSurface? { didSet { if surface != oldValue { apply() } } }
	var isWindowActive = true { didSet { if isWindowActive != oldValue { apply() } } }

	private let material = NSVisualEffectView()
	private let tint = CALayer()
	private let backdrop = CALayer()
	private let shadowHost = CALayer()
	private let shadowLayer = CAShapeLayer()
	private let shadowMask = CAShapeLayer()

	override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		material.blendingMode = .behindWindow
		material.state = .followsWindowActiveState
		material.autoresizingMask = [.width, .height]
		addSubview(material)
		layer?.addSublayer(tint)
		layer?.addSublayer(backdrop)
		shadowLayer.fillRule = .evenOdd
		shadowLayer.fillColor = NSColor.black.cgColor
		shadowHost.mask = shadowMask
		shadowHost.addSublayer(shadowLayer)
		layer?.addSublayer(shadowHost)
		apply()
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override var isFlipped: Bool { true }
	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override func layout() {
		super.layout()
		frameLayers()
	}

	override func viewDidChangeEffectiveAppearance() {
		super.viewDidChangeEffectiveAppearance()
		apply()
	}

	private var isDark: Bool {
		effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
	}

	private func cgColor(_ color: NSColor?) -> CGColor? {
		guard let color else { return nil }
		var result: CGColor?
		effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
		return result
	}

	private func apply() {
		isHidden = surface == nil
		guard let surface else { return }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }
		let look = surface.look(isDark: isDark, isWindowActive: isWindowActive)
		material.isHidden = look.material == nil
		if let m = look.material { material.material = m }
		tint.backgroundColor = cgColor(look.tint)
		backdrop.backgroundColor = cgColor(look.backdrop?.color)
		backdrop.compositingFilter = look.backdrop?.blendMode.compositingFilter
		let inner = isDark ? surface.darkInnerShadow : surface.lightInnerShadow
		shadowHost.isHidden = inner == nil
		if let inner {
			shadowLayer.shadowColor = cgColor(inner.color)
			shadowLayer.shadowOpacity = inner.opacity
			shadowLayer.shadowRadius = inner.blurRadius
			// Layers here are flipped (y down), so a positive offset moves the shadowLayer down.
			shadowLayer.shadowOffset = inner.offset
			shadowHost.compositingFilter = inner.blendMode.compositingFilter
		}
		frameLayers()
	}

	private func frameLayers() {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		defer { CATransaction.commit() }
		let rect = bounds
		tint.frame = rect
		backdrop.frame = rect
		shadowHost.frame = rect
		shadowLayer.frame = rect
		shadowMask.frame = rect
		guard let surface else { return }
		let inner = isDark ? surface.darkInnerShadow : surface.lightInnerShadow
		let radius = min(
			inner?.cornerRadius ?? surface.cornerRadius, min(rect.width, rect.height) / 2)
		let window = CGPath(
			roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
		// A frame around the window casts the shadowLayer inward; the mask keeps only the inside.
		let ring = CGMutablePath()
		ring.addRect(rect.insetBy(dx: -40, dy: -40))
		ring.addPath(window)
		shadowLayer.path = ring
		shadowLayer.shadowPath = ring
		shadowMask.path = window
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
