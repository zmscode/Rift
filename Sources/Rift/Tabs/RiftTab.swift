import AppKit
import RiftCore

/// One tab in a `RiftTabBarView`.
public struct RiftTab<ID: Hashable>: Equatable {
	public var id: ID
	public var title: String
	/// Whether the tab shows a close button and can be closed from its menu.
	public var isClosable: Bool
	/// What the tab is busy doing ("is still working"); closing a busy tab asks first.
	public var activity: String?
	/// An SF Symbol shown before the title.
	public var symbolName: String?

	public init(
		id: ID, title: String, symbolName: String? = nil, isClosable: Bool = true,
		activity: String? = nil
	) {
		self.id = id
		self.title = title
		self.symbolName = symbolName
		self.isClosable = isClosable
		self.activity = activity
	}
}

// MARK: - Looks

/// The tab bar's three surfaces: the track behind the tabs, the selected tab, and a hovered tab.
public struct RiftTabSurfaces: Hashable, Sendable {
	public struct Looks: Hashable, Sendable {
		public var track: RiftSurfaceStyle
		public var inactiveWindowTrack: RiftSurfaceStyle
		public var selection: RiftSurfaceStyle
		public var inactiveWindowSelection: RiftSurfaceStyle
		public var hover: RiftSurfaceStyle
		/// How far the track is drawn inside its frame.
		public var trackInset: CGFloat

		public init(
			track: RiftSurfaceStyle, inactiveWindowTrack: RiftSurfaceStyle,
			selection: RiftSurfaceStyle, inactiveWindowSelection: RiftSurfaceStyle,
			hover: RiftSurfaceStyle, trackInset: CGFloat = 0
		) {
			self.trackInset = trackInset
			self.track = track
			self.inactiveWindowTrack = inactiveWindowTrack
			self.selection = selection
			self.inactiveWindowSelection = inactiveWindowSelection
			self.hover = hover
		}
	}

	public var light: Looks
	public var dark: Looks

	public init(light: Looks, dark: Looks) {
		self.light = light
		self.dark = dark
	}

	/// The built-in look.
	///
	/// - Track: a 40pt-radius capsule, white at 5% (dark; 3% in background windows, 2% compact, and
	///   inset 1pt in compact), black at 5% (light; plus-darker in comfortable; none in background
	///   windows).
	/// - Selected tab: plain glass at 16.5pt corners. Dark background windows add a 1pt white
	///   outline at 5%. Light adds a 25% tint (the canvas; white in compact) and, in the key window,
	///   a soft shadow (black at 40%, opacity 0.15, 3.5pt blur, 1.5pt down).
	/// - Hovered tab: white at 13% (10% compact) with a 5% white overlay on top (dark),
	///   plus-darker black at 5% (light).
	public static func modern(_ density: RiftChromeDensity) -> RiftTabSurfaces {
		func rgb(_ v: CGFloat, _ a: CGFloat) -> NSColor {
			NSColor(srgbRed: v, green: v, blue: v, alpha: a)
		}
		let canvas: CGFloat = 0.117647
		let compact = density == .compact

		var darkTrack = RiftSurfaceStyle()
		darkTrack.cornerRadius = RiftTabBarMath.trackCornerRadius
		darkTrack.fill = RiftSurfaceFill(color: rgb(1, 0.05))
		var darkInactiveTrack = darkTrack
		darkInactiveTrack.fill = RiftSurfaceFill(color: rgb(1, compact ? 0.02 : 0.03))
		var darkSelection = RiftSurfaceStyle()
		darkSelection.cornerRadius = RiftTabBarMath.tabCornerRadius
		darkSelection.glass = RiftSurfaceGlass()
		var darkInactiveSelection = darkSelection
		darkInactiveSelection.strokes = [RiftSurfaceStroke(color: rgb(1, 0.05))]
		var darkHover = RiftSurfaceStyle()
		darkHover.cornerRadius = RiftTabBarMath.tabCornerRadius
		darkHover.backdrop = RiftSurfaceFill(color: rgb(1, compact ? 0.1 : 0.13))
		darkHover.fill = RiftSurfaceFill(color: rgb(1, 0.05), blendMode: .overlay)

		var lightTrack = RiftSurfaceStyle()
		lightTrack.cornerRadius = RiftTabBarMath.trackCornerRadius
		lightTrack.fill = RiftSurfaceFill(
			color: rgb(0, 0.05), blendMode: compact ? .normal : .plusDarker, role: .content)
		var lightInactiveTrack = RiftSurfaceStyle()
		lightInactiveTrack.cornerRadius = RiftTabBarMath.trackCornerRadius
		var lightInactiveSelection = RiftSurfaceStyle()
		lightInactiveSelection.cornerRadius = RiftTabBarMath.tabCornerRadius
		lightInactiveSelection.glass = RiftSurfaceGlass(
			tint: compact ? rgb(1, 0.25) : rgb(canvas, 0.25), tintRole: .canvas)
		var lightSelection = lightInactiveSelection
		lightSelection.shadows = [
			RiftSurfaceShadow(
				color: rgb(0, 0.4), opacity: 0.15, radius: 3.5,
				offset: CGSize(width: 0, height: 1.5),
				role: .content)
		]
		var lightHover = RiftSurfaceStyle()
		lightHover.cornerRadius = RiftTabBarMath.tabCornerRadius
		lightHover.fill = RiftSurfaceFill(
			color: rgb(0, 0.05), blendMode: .plusDarker, role: .contentSecondary)

		return RiftTabSurfaces(
			light: Looks(
				track: lightTrack, inactiveWindowTrack: lightInactiveTrack,
				selection: lightSelection,
				inactiveWindowSelection: lightInactiveSelection, hover: lightHover),
			dark: Looks(
				track: darkTrack, inactiveWindowTrack: darkInactiveTrack, selection: darkSelection,
				inactiveWindowSelection: darkInactiveSelection, hover: darkHover,
				trackInset: compact ? 1 : 0))
	}

	/// These looks in a theme's colours: role-bound colours (the light track, hover, selection tint
	/// and shadow) take their role's colour, canvas greys the theme's canvas.
	public func themed(_ selection: RiftThemeSelection) -> RiftTabSurfaces {
		func looks(_ l: Looks, _ theme: RiftTheme) -> Looks {
			Looks(
				track: l.track.rift_themed(theme),
				inactiveWindowTrack: l.inactiveWindowTrack.rift_themed(theme),
				selection: l.selection.rift_themed(theme),
				inactiveWindowSelection: l.inactiveWindowSelection.rift_themed(theme),
				hover: l.hover.rift_themed(theme), trackInset: l.trackInset)
		}
		return RiftTabSurfaces(
			light: looks(light, selection.light), dark: looks(dark, selection.dark))
	}

	func looks(isDark: Bool) -> Looks { isDark ? dark : light }
}

// MARK: - Pane drops
