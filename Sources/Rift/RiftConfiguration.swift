import AppKit
import RiftCore

/// Why a `RiftView` changed its layout. Delivered with `onLayoutChange`.
public enum RiftChangeReason: Sendable, Equatable {
	case split
	case close
	/// A pane was dragged to a new place in the same view.
	case move
	/// A pane arrived from another view.
	case transferIn
	/// A pane left for another view.
	case transferOut
	/// A pane was dragged out of every window.
	case tearOut
	case dividerDrag
	case resize
	case balance
}

/// How the window hosting a `RiftView` draws its titlebar.
public enum RiftWindowStyle: Sendable, Equatable {
	/// Leave the window alone.
	case standard
	/// Hide the titlebar and title, run content edge to edge, and centre the system window buttons
	/// in the top row of pane headers. Panes under the buttons leave room for them, and pane
	/// headers drag the window. The view should fill the window's content view.
	case headless
}

/// What dragging a pane header does.
public enum RiftHeaderDragBehavior: Sendable, Equatable {
	/// Move the window in headless mode, otherwise move the pane.
	case automatic
	/// Always move the pane (rearrange the layout).
	case movePane
	/// Always move the window. Panes are moved with the header's grip, or by Option-dragging the header.
	case moveWindow
}

/// Appearance and behaviour of a `RiftView`.
public struct RiftConfiguration: Equatable {
	// Window
	public var windowStyle: RiftWindowStyle = .standard
	public var headerDragBehavior: RiftHeaderDragBehavior = .automatic
	/// Space kept between the window buttons and pane header content, used only when
	/// `windowButtonInset` is `nil`.
	public var windowButtonSpacing: CGFloat = 8
	/// Width kept clear for the window buttons at the window's leading edge, in a headless window.
	/// 76pt covers the close, minimise and zoom buttons. `nil` measures the buttons instead.
	public var windowButtonInset: CGFloat? = 76
	/// The titlebar height and window-button offset for headless windows. `nil` centres the
	/// buttons in the pane header row (`headerHeight`).
	public var titlebarMetrics: RiftTitlebarMetrics? = nil

	/// What is drawn behind each pane's content (background, glass, fills, strokes), and how
	/// opaque the content is per state. `nil` (the default) draws nothing; content draws its own
	/// background. Use `RiftPaneSurfaces.modern(_:)` or your own `RiftPaneSurfaceProviding`.
	public var paneSurface: RiftPaneSurface?
	/// Colours for everything Rift draws: the built-in surfaces' tints take the theme's canvas,
	/// the border presets its accent and terminal colours, divider lines its text colour, the drop
	/// highlight its accent. Pane content gets it in the SwiftUI environment
	/// (`riftThemeSelection`, or `RiftThemeReader`). `nil` uses the system colours.
	public var theme: RiftThemeSelection?
	/// The surface behind the whole layout (window material, tint, inner shadow). `nil` draws none.
	public var windowSurface: RiftWindowSurface?
	/// What an unfocused pane loses: its surface look (`styling`), its content opacity (`text`),
	/// both, or neither.
	public var inactivePaneFade: RiftInactivePaneFade = .both

	public var metrics = RiftMetrics()
	public var snap = RiftSnapConfiguration()

	// Dividers
	public var showsDividerLines = true
	public var dividerColor: NSColor = .separatorColor
	/// How divider lines blend with what is behind them.
	public var dividerBlendMode: RiftDividerBlendMode = .normal
	public var allowsDividerDragging = true
	/// Keyboard and accessibility resize step, as a fraction of the split being resized.
	public var keyboardResizeFraction: Double = 0.05
	/// Rebalance panes when one opens or closes, keeping dividers the user dragged.
	public var autoBalance = false
	/// Play a haptic tick when a dragged divider snaps to the center.
	public var hapticFeedback = true

	// Panes
	/// Show a header bar (title, close button) on each pane. When off (the default), each pane
	/// instead has an invisible strip along its top: the top-left corner drags the pane, and for
	/// panes at the top of a headless window the rest of the strip drags the window.
	public var showsPaneHeaders = false
	/// Height of the header bar, or of the invisible strip when headers are off. In a headless
	/// window this is also the row the window buttons are centred in.
	public var headerHeight: CGFloat = 28
	/// Space kept above pane content when headers are off (like a terminal's top padding).
	/// The invisible top strip still sits over it. 0 lets content reach the top edge.
	public var headerlessTopInset: CGFloat = 0
	/// Width of the top-left corner of a pane that drags it (when headers are off).
	public var dragHandleWidth: CGFloat = 44
	public var showsCloseButtons = true
	public var paneCornerRadius: CGFloat = 0
	public var showsFocusBorder = true
	/// `nil` uses the system accent color.
	public var focusBorderColor: NSColor?
	/// A named border colour, resolved through `colorPalette`. `focusBorderColor` wins when set.
	public var focusBorderPreset: RiftFocusBorderColor = .accent
	/// The colours the presets name: system colours by default; give your app's (or terminal
	/// theme's) palette to match it.
	public var colorPalette = RiftColorPalette()
	public var focusBorderWidth: CGFloat = 2
	/// How the focus border gets from one pane to the next.
	public var focusBorderTransition: RiftFocusBorderTransition = .crossfade
	/// Multiplies the focus border's opacity while the window isn't key.
	public var inactiveWindowFocusBorderOpacity: CGFloat = 0.35
	/// Opacity of the focus border (before the inactive-window factor).
	public var focusBorderOpacity: CGFloat = 1
	/// Stroke the focus border with a gradient: the colour mixed 10% toward white, the colour,
	/// and the colour mixed 10% toward black (perceptually), at `focusBorderGradientAngle`.
	public var focusBorderUsesGradient = true
	/// Degrees; 135 runs from the top-left corner to the bottom-right.
	public var focusBorderGradientAngle: Double = 135
	/// Corners of the border that touch the edge of the layout follow the window's corners
	/// (`layoutCornerRadius`) instead of the pane's.
	public var focusBorderFollowsWindowCorners = true
	/// The radius of the layout's outer corners, usually the window's. `nil` uses the pane radius.
	public var layoutCornerRadius: CGFloat? = nil
	/// Hide divider lines where they run under the focus border, so they don't show through it
	/// or poke out past its rounded corners.
	public var focusBorderCoversDividers = true
	/// Alpha applied to the content of panes that don't have focus (1 = no fading).
	public var inactivePaneAlpha: CGFloat = 0.7
	/// Content alpha while the window isn't key, for the focused pane and for the others.
	/// Set both to the active values to keep panes the same in background windows.
	public var inactiveWindowFocusedPaneAlpha: CGFloat = 0.8
	public var inactiveWindowPaneAlpha: CGFloat = 0.5
	/// Hide the scrollers of scroll views inside panes while panes are being reshaped
	/// (`structuralActivity` is not empty), so they don't flash.
	public var hidesScrollersDuringStructuralChanges = true
	/// How pane content is sized while the layout moves.
	public var paneContentSizing: RiftPaneContentSizing = .followsSurface
	/// Hold a zooming pane's content at its larger size while the zoom animates.
	public var pinsContentDuringZoom = false
	public var focusFollowsMouse = false

	/// Double-clicking a divider centres it. Off by default.
	public var doubleClickCentersDivider = false
	/// Spreading two fingers over a pane zooms it; pinching restores the layout.
	public var allowsPinchToZoom = true

	// Pane drag and drop
	public var allowsPaneDragging = true
	/// Allow dropping on the middle of a pane in the same view to swap the two panes. When off, and
	/// always for panes dragged from another view, the middle of a pane is not a drop target.
	public var allowsCenterDrop = true
	/// Preferred width of the edge bands that split a pane on drop.
	public var dropBand: CGFloat = 80
	public var dropIndicatorInset: CGFloat = 4
	public var dropIndicatorCornerRadius: CGFloat = 8
	/// `nil` uses the system accent color.
	public var dropIndicatorColor: NSColor?
	/// Draw the drop highlight in a child window above this one, so it shows over glass and
	/// anything else in the window. Off draws it as a view above the panes.
	public var dropIndicatorUsesChildWindow = true
	/// Distance the mouse must travel before a pane drag starts.
	/// 0 (the default) starts the drag on the first mouse-dragged event; a press that ends
	/// without moving is passed through to the pane content as a click.
	public var dragStartDistance: CGFloat = 0
	public var dragPreviewMaxSize = CGSize(width: 280, height: 200)

	// Motion
	/// How layout changes move. `.snappy` uses a critically damped spring (about 0.41s);
	/// `.natural` a spring with a slight overshoot (about 0.54s); `.off` moves panes at once.
	/// Reduce Motion always behaves like `.off`.
	public var animationStyle: RiftAnimationStyle = .snappy
	/// Multiplies the durations of panes appearing and disappearing.
	public var popInTimeScale: Double = 1
	/// How panes appear and disappear for the current `animationStyle`, or `nil` when it is `.off`.
	/// How panes appear and disappear.
	public var paneTransition: RiftPaneTransitionKind = .popIn
	/// The transition with its timings, or `nil` when motion is off.
	public var paneTransitionStyle: RiftPaneTransitionStyle? {
		switch paneTransition {
		case .popIn: panePopIn.map { .popIn($0) }
		case .edgeGrowth: animationStyle.paneCurve == nil ? nil : .edgeGrowth
		}
	}
	public var panePopIn: RiftPanePopIn? {
		animationStyle.paneCurve.map { .standard(entryCurve: $0, timeScale: popInTimeScale) }
	}

	public init() {}
}

/// What is reshaping a `RiftView`'s panes right now.
public struct RiftStructuralActivity: OptionSet, Sendable, Hashable {
	public let rawValue: Int
	public init(rawValue: Int) { self.rawValue = rawValue }

	/// An animated layout change (split, close, move, zoom, balance…) is running.
	public static let structuralTransition = RiftStructuralActivity(rawValue: 1 << 0)
	/// A divider is being dragged.
	public static let dividerDrag = RiftStructuralActivity(rawValue: 1 << 1)
	/// The window is being resized live.
	public static let windowLiveResize = RiftStructuralActivity(rawValue: 1 << 2)
	/// A pane is being dragged.
	public static let paneDrag = RiftStructuralActivity(rawValue: 1 << 3)
}

/// How the focus border moves when focus changes.
/// How panes appear and disappear (see `RiftPaneTransitionStyle`).
public enum RiftPaneTransitionKind: String, Sendable, Hashable, CaseIterable {
	case popIn
	case edgeGrowth
}

/// How pane content is sized while the layout moves.
public enum RiftPaneContentSizing: String, Sendable, Hashable, CaseIterable {
	/// Content follows its pane on every frame.
	case followsSurface
	/// Content keeps the larger of its start and end size until the motion ends, clipped to the
	/// pane, so it reflows once.
	case pinnedDuringMotion
}

/// What an unfocused pane loses.
public enum RiftInactivePaneFade: String, Sendable, Hashable, CaseIterable {
	case none
	/// The surface takes its unfocused look; content stays fully opaque.
	case styling
	/// Content takes the unfocused opacity; the surface keeps its focused look.
	case text
	case both

	public var fadesStyling: Bool { self == .styling || self == .both }
	public var fadesText: Bool { self == .text || self == .both }
}

public enum RiftFocusBorderTransition: String, Sendable, Hashable, CaseIterable {
	/// The border slides from the old pane to the new one on the pane motion curve, taking half
	/// that curve's transition time.
	case glide
	/// The old border fades out while the new one fades in (0.539s on bezier(0.23, 1, 0.32, 1)).
	case crossfade
	/// The border jumps.
	case off
}

extension RiftConfiguration {
	/// Panes as separate cards: an 8pt gap between them, no divider lines, 10pt corners.
	public static var comfortable: RiftConfiguration {
		var configuration = RiftConfiguration()
		configuration.metrics.dividerThickness = 8
		configuration.showsDividerLines = false
		configuration.dividerColor = .clear
		configuration.paneCornerRadius = 10
		configuration.dropIndicatorCornerRadius = 8
		configuration.layoutCornerRadius = 12
		configuration.paneSurface = RiftPaneSurface(.modern(.comfortable))
		configuration.windowSurface = .modern(.comfortable)
		return configuration
	}

	/// Panes that touch, separated by a 1pt line at 70% opacity, with square corners.
	public static var compact: RiftConfiguration {
		var configuration = RiftConfiguration()
		// Panes touch; a 1pt line is drawn over their shared edge.
		configuration.metrics.dividerThickness = 0
		configuration.metrics.lineThickness = 1
		configuration.showsDividerLines = true
		configuration.dividerColor = NSColor(name: nil) { appearance in
			appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
				? NSColor(white: 1, alpha: 0.7) : NSColor(white: 0, alpha: 0.7)
		}
		configuration.dividerBlendMode = .automatic
		configuration.paneCornerRadius = 0
		configuration.dropIndicatorCornerRadius = 0
		configuration.layoutCornerRadius = 12
		configuration.paneSurface = RiftPaneSurface(.modern(.compact))
		configuration.windowSurface = .modern(.compact)
		return configuration
	}
}

/// Blend modes for divider lines (Core Animation compositing filters).
public enum RiftDividerBlendMode: String, Sendable, Hashable, CaseIterable {
	case normal, plusDarker, plusLighter, colorDodge, overlay, color
	/// Plus-lighter in dark mode, plus-darker in light mode.
	case automatic

	/// The filter for this mode in the given appearance.
	public func compositingFilter(isDark: Bool) -> String? {
		self == .automatic
			? (isDark ? RiftDividerBlendMode.plusLighter : .plusDarker).compositingFilter
			: compositingFilter
	}

	/// The `CALayer.compositingFilter` name, or `nil` for normal blending (and for `automatic`,
	/// which needs the appearance: see `compositingFilter(isDark:)`).
	public var compositingFilter: String? {
		switch self {
		case .normal, .automatic: nil
		case .plusDarker: "plusD"
		case .plusLighter: "plusL"
		case .colorDodge: "colorDodgeBlendMode"
		case .overlay: "overlayBlendMode"
		case .color: "colorBlendMode"
		}
	}
}

/// The titlebar height and window-button group offset a headless window uses (where AppKit takes
/// them; see `RiftHeadlessWindow`). Not applied in full screen.
public struct RiftTitlebarMetrics: Equatable, Sendable {
	public var height: CGFloat
	/// Positive x moves the buttons right, positive y down.
	public var buttonOffset: CGPoint

	public init(height: CGFloat, buttonOffset: CGPoint) {
		self.height = height
		self.buttonOffset = buttonOffset
	}

	private static var baseX: CGFloat {
		ProcessInfo.processInfo.isOperatingSystemAtLeast(
			OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 8 : 10
	}

	/// With a sidebar beside the layout: a 42pt titlebar, buttons moved 1pt right and 4pt down
	/// (compact: 5pt left and 2pt up) from 8pt in (10pt before macOS 26).
	public static func sidebar(_ density: RiftChromeDensity) -> Self {
		let compact = density == .compact
		return Self(
			height: 42, buttonOffset: CGPoint(x: baseX + (compact ? -5 : 1), y: compact ? -2 : 4))
	}

	/// With a horizontal tab bar across the top: a 46pt titlebar (40 compact), buttons 1pt (4pt
	/// compact) left of the base inset.
	public static func tabBar(_ density: RiftChromeDensity) -> Self {
		let compact = density == .compact
		return Self(height: compact ? 40 : 46, buttonOffset: CGPoint(x: baseX - (compact ? 4 : 1), y: 0))
	}
}

/// The named colours a focus border can take.
public enum RiftFocusBorderColor: String, Sendable, Hashable, CaseIterable {
	case accent, red, blue, green, yellow, cyan, magenta
	/// The content's foreground colour (for a terminal, its text colour).
	case foreground
}

/// The colours behind `RiftFocusBorderColor`.
public struct RiftColorPalette: Equatable {
	public var accent: NSColor = .controlAccentColor
	public var red: NSColor = .systemRed
	public var blue: NSColor = .systemBlue
	public var green: NSColor = .systemGreen
	public var yellow: NSColor = .systemYellow
	public var cyan: NSColor = .systemCyan
	public var magenta: NSColor = .systemPink
	public var foreground: NSColor = .labelColor

	public init() {}

	public func color(_ name: RiftFocusBorderColor) -> NSColor {
		switch name {
		case .accent: accent
		case .red: red
		case .blue: blue
		case .green: green
		case .yellow: yellow
		case .cyan: cyan
		case .magenta: magenta
		case .foreground: foreground
		}
	}
}
