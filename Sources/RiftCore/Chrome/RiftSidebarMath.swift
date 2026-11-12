import CoreGraphics
import Foundation

/// Which side of the window a sidebar sits on.
public enum RiftSidebarPosition: String, Codable, Sendable, Hashable, CaseIterable {
	case left, right
}

/// How tightly the window chrome is packed.
public enum RiftChromeDensity: String, Codable, Sendable, Hashable, CaseIterable {
	case comfortable, compact
}

/// When a two-finger horizontal swipe folds or unfolds the sidebar.
public enum RiftSidebarSwipe: String, Codable, Sendable, Hashable, CaseIterable {
	/// A plain swipe (not over something that scrolls sideways, and without ⌥).
	case swipe
	/// Only a swipe with ⌥ held.
	case optionSwipe
	case off
}

/// The numbers behind the sidebar: widths, the window-button room panes keep, the toggle button's
/// place, the swipe that folds it, and how much the window shrinks when it folds.
public enum RiftSidebarMath {
	public static let defaultWidth: CGFloat = 240
	public static let minimumWidth: CGFloat = 167
	/// The widest a sidebar may be: 60% of the container, at most 480pt (but never under the minimum).
	public static func maximumWidth(containerWidth: CGFloat) -> CGFloat {
		guard containerWidth > 0 else { return 480 }
		return max(min(containerWidth * 0.6, 480), minimumWidth)
	}

	/// A requested width rounded and kept between the minimum and maximum.
	public static func clampedWidth(_ width: CGFloat, containerWidth: CGFloat) -> CGFloat {
		let lower = max(width.rounded(), minimumWidth)
		return min(maximumWidth(containerWidth: containerWidth).rounded(.down), lower)
	}

	/// Room pane headers keep at their leading edge for the window buttons (and the toggle).
	///
	/// - Sidebar on the right: 76pt (0 in full screen); the buttons sit over the panes.
	/// - Sidebar on the left: none while it is open (the buttons sit over the sidebar), growing to
	///   116pt as it folds (32 in full screen; 6 less in compact density; 36 less without a
	///   toggle button).
	public static func leadingButtonRoom(
		position: RiftSidebarPosition, collapseProgress: CGFloat, isFullScreen: Bool,
		density: RiftChromeDensity, hidesToggle: Bool
	) -> CGFloat {
		switch position {
		case .right:
			return isFullScreen ? 0 : 76
		case .left:
			let base = (isFullScreen ? 32 : 116) - (density == .compact ? 6 : 0)
			return (CGFloat(base) - (hidesToggle ? 36 : 0)) * clamp01(collapseProgress)
		}
	}

	/// Room pane headers keep at their trailing edge: 34pt × progress for a right-hand sidebar's
	/// toggle button, otherwise none.
	public static func trailingButtonRoom(
		position: RiftSidebarPosition, collapseProgress: CGFloat, hidesToggle: Bool
	) -> CGFloat {
		position == .right && !hidesToggle ? 34 * clamp01(collapseProgress) : 0
	}

	/// The sidebar toggle button's frame (28×28) in a container `containerWidth` wide, y down.
	public static func toggleFrame(
		position: RiftSidebarPosition, containerWidth: CGFloat, isFullScreen: Bool,
		density: RiftChromeDensity
	) -> CGRect {
		let compact = density == .compact
		let x: CGFloat
		switch position {
		case .right:
			x = containerWidth - (compact ? 6 : 10) - 28 + (compact ? 3 : 0)
		case .left:
			x = (isFullScreen ? 8 : 92) + (compact ? -5 : 1)
		}
		let y: CGFloat = compact ? 5 : 11
		let dx: CGFloat = compact ? -2 : (position == .right ? -1 : 0)
		return CGRect(x: x + dx, y: y, width: 28, height: 28)
	}

	/// The sidebar's title row (49pt, 38pt compact). Sidebar content starts below it.
	public static func titleRowHeight(density: RiftChromeDensity) -> CGFloat {
		density == .compact ? 38 : 49
	}

	/// The footer row along the bottom of the sidebar, shown when it has buttons. Sidebar content
	/// ends above it.
	public static let footerHeight: CGFloat = 40

	/// Where the footer's buttons go (footer coordinates, y down): 26×26 circles, 4pt apart,
	/// from the trailing edge inward, 11pt in (7pt compact, 6pt for a compact right sidebar).
	/// They sit 1.5pt below the row's centre (centred in compact density). Buttons that would
	/// start before the leading margin (10pt, 7pt compact) are left out.
	public static func footerButtons(
		count: Int, sidebarWidth: CGFloat, position: RiftSidebarPosition,
		density: RiftChromeDensity
	) -> [CGRect] {
		let compact = density == .compact
		let margin: CGFloat = compact ? 7 : 11
		let nudge: CGFloat = compact && position == .right ? 1 : 0
		let y = (footerHeight + (compact ? 0 : 3) - 26) / 2
		let leading: CGFloat = compact ? 7 : 10
		var frames: [CGRect] = []
		for index in 0..<max(count, 0) {
			let x = sidebarWidth - margin - 26 + nudge - CGFloat(index) * 30
			guard x >= leading else { break }
			frames.append(CGRect(x: x, y: y, width: 26, height: 26))
		}
		return frames
	}

	/// Where the sidebar's own buttons go in its title row (sidebar coordinates, y down): 28×28,
	/// 2pt apart, starting 10pt (6pt compact) in from the sidebar's outer edge and running toward
	/// the window buttons, never into the `clearance` they take. When not all of `count` fit, the
	/// last slot is a "more" button (`overflow` is how many buttons it holds).
	public static func titleRowButtons(
		count: Int, sidebarWidth: CGFloat, position: RiftSidebarPosition,
		density: RiftChromeDensity, clearance: CGFloat
	) -> (frames: [CGRect], more: CGRect?, overflow: Int) {
		guard count > 0 else { return ([], nil, 0) }
		let compact = density == .compact
		let margin: CGFloat = compact ? 6 : 10
		let y: CGFloat = compact ? 5 : 11
		let slots = max(1, Int(((sidebarWidth - margin - clearance + 2) / 30).rounded(.down)))
		func frame(_ index: Int) -> CGRect {
			let offset = CGFloat(index) * 30
			let x =
				position == .left
				? sidebarWidth - margin - 28 - offset
				: margin + offset
			return CGRect(x: x, y: y, width: 28, height: 28)
		}
		if count <= slots { return ((0..<count).map(frame), nil, 0) }
		let shown = slots - 1
		return ((0..<shown).map(frame), frame(shown), count - shown)
	}

	/// The width of the strip that resizes the sidebar, centred on its inner edge.
	public static let resizeHandleWidth: CGFloat = 8

	/// A swipe folds the sidebar once its horizontal travel reaches 44pt while staying mostly
	/// horizontal (|dy| × 1.6 < |dx|).
	public static func swipeIsRecognized(travel: CGSize) -> Bool {
		abs(travel.width) >= 44 && abs(travel.height) * 1.6 < abs(travel.width)
	}

	/// Whether a recognized swipe of `dx` folds (true) or unfolds (false) the sidebar: toward the
	/// sidebar's side folds it.
	public static func swipeCollapses(dx: CGFloat, position: RiftSidebarPosition) -> Bool {
		position == .left ? dx < 0 : dx > 0
	}

	/// The smallest a window may be with the sidebar open.
	public static let expandedWindowMinimumWidth: CGFloat = 720
	/// How much a window `windowWidth` wide shrinks when a sidebar `sidebarWidth` wide folds: the
	/// sidebar's width, but never below max(720 − sidebar, 480) wide.
	public static func collapsedWindowShrink(windowWidth: CGFloat, sidebarWidth: CGFloat) -> CGFloat
	{
		let width = max(0, sidebarWidth)
		let floor = max(expandedWindowMinimumWidth - width, 480)
		return min(width, max(0, windowWidth - floor))
	}

	/// Whether folding leaves the window's width alone because the window (nearly) fills its
	/// screen: it is on screen and at most 64pt narrower than the screen's visible area.
	public static func windowFillsScreen(windowFrame: CGRect, screenFrame: CGRect) -> Bool {
		guard !screenFrame.isEmpty, windowFrame.intersects(screenFrame) else { return false }
		return windowFrame.width >= screenFrame.width - 64
	}

	/// How long a fold on `curve` takes: a spring's settling time, else 0.3 seconds.
	public static func foldDuration(curve: RiftMotionCurve) -> Double {
		curve.settlingDuration ?? 0.3
	}

	/// The sidebar fades out over this long (ease-out) once it has folded away.
	public static let fadeOutDuration: Double = 0.16

	/// The smallest a window may be with the sidebar folded after shrinking by `shrink`.
	public static func collapsedWindowMinimumWidth(shrink: CGFloat) -> CGFloat {
		max(expandedWindowMinimumWidth - shrink, 480)
	}

	static func clamp01(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
}
