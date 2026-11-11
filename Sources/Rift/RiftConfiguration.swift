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

	/// What is drawn behind each pane's content (background, glass, fills, strokes), and how
	/// opaque the content is per state. `nil` (the default) draws nothing; content draws its own
	/// background. Use `RiftPaneSurfaces.modern(_:)` or your own `RiftPaneSurfaceProviding`.
	public var paneSurface: RiftPaneSurface?

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
	public var focusBorderWidth: CGFloat = 2
	/// How the focus border gets from one pane to the next.
	public var focusBorderTransition: RiftFocusBorderTransition = .glide
	/// Multiplies the focus border's opacity while the window isn't key.
	public var inactiveWindowFocusBorderOpacity: CGFloat = 0.35
	/// Opacity of the focus border (before the inactive-window factor).
	public var focusBorderOpacity: CGFloat = 1
	/// Alpha applied to the content of panes that don't have focus (1 = no fading).
	public var inactivePaneAlpha: CGFloat = 0.7
	/// Content alpha while the window isn't key, for the focused pane and for the others.
	/// Set both to the active values to keep panes the same in background windows.
	public var inactiveWindowFocusedPaneAlpha: CGFloat = 0.8
	public var inactiveWindowPaneAlpha: CGFloat = 0.5
	/// Hide the scrollers of scroll views inside panes while panes are being reshaped
	/// (`structuralActivity` is not empty), so they don't flash.
	public var hidesScrollersDuringStructuralChanges = true
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
		configuration.dividerColor = .clear
		configuration.paneCornerRadius = 10
		configuration.dropIndicatorCornerRadius = 8
		configuration.paneSurface = RiftPaneSurface(.modern(.comfortable))
		return configuration
	}

	/// Panes that touch, separated by a 1pt line at 70% opacity, with square corners.
	public static var compact: RiftConfiguration {
		var configuration = RiftConfiguration()
		configuration.metrics.dividerThickness = 1
		configuration.showsDividerLines = true
		configuration.dividerColor = NSColor.separatorColor.withAlphaComponent(0.7)
		configuration.paneCornerRadius = 0
		configuration.dropIndicatorCornerRadius = 0
		configuration.paneSurface = RiftPaneSurface(.modern(.compact))
		return configuration
	}
}

/// Blend modes for divider lines (Core Animation compositing filters).
public enum RiftDividerBlendMode: String, Sendable, Hashable, CaseIterable {
	case normal, plusDarker, plusLighter, colorDodge, overlay, color

	/// The `CALayer.compositingFilter` name, or `nil` for normal blending.
	public var compositingFilter: String? {
		switch self {
		case .normal: nil
		case .plusDarker: "plusD"
		case .plusLighter: "plusL"
		case .colorDodge: "colorDodgeBlendMode"
		case .overlay: "overlayBlendMode"
		case .color: "colorBlendMode"
		}
	}
}
