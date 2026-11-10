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
public struct RiftConfiguration {
	// Window
	public var windowStyle: RiftWindowStyle = .standard
	public var headerDragBehavior: RiftHeaderDragBehavior = .automatic
	/// Space kept between the window buttons and pane header content.
	public var windowButtonSpacing: CGFloat = 8

	/// Liquid glass behind panes. Off by default.
	public var glass = RiftGlassConfiguration()

	public var metrics = RiftMetrics()
	public var snap = RiftSnapConfiguration()

	// Dividers
	public var showsDividerLines = true
	public var dividerColor: NSColor = .separatorColor
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
	/// Width of the top-left corner of a pane that drags it (when headers are off).
	public var dragHandleWidth: CGFloat = 44
	public var showsCloseButtons = true
	public var paneCornerRadius: CGFloat = 0
	public var showsFocusBorder = true
	/// `nil` uses the system accent color.
	public var focusBorderColor: NSColor?
	public var focusBorderWidth: CGFloat = 2
	/// Alpha applied to the content of panes that don't have focus (1 = no fading).
	public var inactivePaneAlpha: CGFloat = 1
	public var focusFollowsMouse = false

	// Pane drag and drop
	public var allowsPaneDragging = true
	/// Allow dropping on the middle of a pane in the same view to swap the two panes.
	public var allowsCenterDrop = true
	/// Preferred width of the edge bands that split a pane on drop.
	public var dropBand: CGFloat = 80
	public var dropIndicatorInset: CGFloat = 4
	public var dropIndicatorCornerRadius: CGFloat = 8
	/// `nil` uses the system accent color.
	public var dropIndicatorColor: NSColor?
	/// Distance the mouse must travel before a pane drag starts.
	public var dragStartDistance: CGFloat = 4
	public var dragPreviewMaxSize = CGSize(width: 280, height: 200)

	// Motion
	public var animationDuration: TimeInterval = 0.2

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
