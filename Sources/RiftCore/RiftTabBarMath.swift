import CoreGraphics
import Foundation

/// The numbers behind a tab bar: sizes, tab widths and frames, scrolling, the dragged tab's
/// rubber-banded position, where a dragged tab lands, and each tab's own layout.
public enum RiftTabBarMath {
	/// The widest a tab grows.
	public static let maximumTabWidth: CGFloat = 240
	/// The narrowest a tab shrinks before the bar scrolls.
	public static let minimumTabWidth: CGFloat = 64
	/// The gap between neighbouring tabs.
	public static let tabGap: CGFloat = 1
	/// How far the pointer moves before a press on a tab becomes a drag.
	public static let dragThreshold: CGFloat = 4
	/// How long a dragged pane hovers over a tab before the tab opens.
	public static let springLoadDelay: TimeInterval = 0.32
	/// How long tabs take to slide to new places.
	public static let geometryDuration: TimeInterval = 0.28
	/// The selected tab's and hover's corner radius (capped at half the tab's height).
	public static let tabCornerRadius: CGFloat = 16.5
	/// How far a dragged tab (and the track that follows it) can travel past the strip's ends.
	public static let trackOvershoot: CGFloat = 60
	/// The track's corner radius.
	public static let trackCornerRadius: CGFloat = 40

	/// The bar's buttons (new tab): 34pt square, 32 in compact density; 2pt less with one tab.
	public static func buttonSize(density: RiftChromeDensity, tabCount: Int = 2) -> CGFloat {
		(density == .compact ? 32 : 34) - (tabCount == 1 ? 2 : 0)
	}

	/// A tab's height: 30pt, 28 in compact density.
	public static func tabHeight(density: RiftChromeDensity) -> CGFloat {
		density == .compact ? 28 : 30
	}

	/// The gap between the bar's buttons and the tab track: 6pt, 4 in compact density.
	public static func spacing(density: RiftChromeDensity) -> CGFloat {
		density == .compact ? 4 : 6
	}

	/// Each tab's width: the available width shared out (less the 1pt gaps), capped at 240 unless
	/// `fills` (and there are at least two tabs), and never under 64.
	public static func tabWidth(available: CGFloat, count: Int, fills: Bool) -> CGFloat {
		guard count > 0 else { return maximumTabWidth }
		let shared = (available - CGFloat(count - 1) * tabGap) / CGFloat(count)
		let width = (fills && count > 1) || shared < maximumTabWidth ? shared : maximumTabWidth
		return max(width, minimumTabWidth)
	}

	/// Tab frames in a row starting at `leading`, 1pt apart, `height` tall and centred on `midY`.
	public static func tabFrames(
		leading: CGFloat, width: CGFloat, count: Int, midY: CGFloat, height: CGFloat
	) -> [CGRect] {
		(0..<max(count, 0)).map { index in
			CGRect(
				x: leading + (width + tabGap) * CGFloat(index), y: (midY - height / 2).rounded(),
				width: width, height: height)
		}
	}

	/// The width of all tabs side by side.
	public static func contentWidth(tabWidth: CGFloat, count: Int) -> CGFloat {
		guard count > 0 else { return 0 }
		return tabWidth * CGFloat(count) + CGFloat(count - 1) * tabGap
	}

	/// How far the tabs can scroll: the overflow beyond the track less 2pt at each end.
	public static func maximumScrollOffset(tabWidth: CGFloat, count: Int, trackWidth: CGFloat)
		-> CGFloat
	{
		max(0, contentWidth(tabWidth: tabWidth, count: count) - (trackWidth - 4))
	}

	/// The scroll offset that brings `tab` (in content coordinates, 0 at the first tab) inside the
	/// track with a 2pt inset, moving as little as possible.
	public static func revealingOffset(
		current: CGFloat, tabMinX: CGFloat, tabMaxX: CGFloat, trackWidth: CGFloat, maximum: CGFloat
	) -> CGFloat {
		var offset = current
		let visibleWidth = trackWidth - 4
		if tabMinX < offset { offset = tabMinX }
		if tabMaxX > offset + visibleWidth { offset = tabMaxX - visibleWidth }
		return min(max(offset, 0), maximum)
	}

	/// A value pulled past `lower...upper` resists: it can travel at most 60pt beyond, easing in
	/// as `1 − e^(−overshoot / 180)`.
	public static func rubberBanded(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
		let upper = max(upper, lower)
		if value < lower { return lower - (1 - exp(-(lower - value) / 180)) * 60 }
		if value > upper { return upper + (1 - exp(-(value - upper) / 180)) * 60 }
		return value
	}

	/// Where a dragged tab sits: its start origin moved with the pointer, kept to the track (with
	/// rubber-banding past either end).
	public static func draggedOrigin(
		pointer: CGPoint, startPointer: CGPoint, startOrigin: CGPoint, size: CGSize, track: CGRect
	) -> CGPoint {
		let x = startOrigin.x + (pointer.x - startPointer.x)
		let y = startOrigin.y + (pointer.y - startPointer.y)
		return CGPoint(
			x: rubberBanded(x, lower: track.minX, upper: track.maxX - size.width),
			y: rubberBanded(y, lower: track.minY, upper: track.maxY - size.height))
	}

	/// The slot a dragged tab moves to, given its centre and the slots' centres. It moves past a
	/// neighbour once its centre is beyond the midpoint between the two slots by a tenth of their
	/// distance (at most 8pt), which keeps it from flickering between two slots.
	public static func reorderedIndex(draggedMidX x: CGFloat, current: Int, slotMidXs: [CGFloat])
		-> Int
	{
		guard slotMidXs.indices.contains(current) else { return current }
		func margin(_ a: CGFloat, _ b: CGFloat) -> CGFloat { min((b - a) * 0.1, 8) }
		var index = current
		while index + 1 < slotMidXs.count {
			let a = slotMidXs[index]
			let b = slotMidXs[index + 1]
			if x <= (a + b) / 2 + margin(a, b) { break }
			index += 1
		}
		if index != current { return index }
		while index > 0 {
			let a = slotMidXs[index - 1]
			let b = slotMidXs[index]
			if x >= (a + b) / 2 - margin(a, b) { break }
			index -= 1
		}
		return index
	}

	/// Whether the divider at a tab's leading edge shows: not before the first tab, nor beside the
	/// selected, hovered or dragged tab (whose surfaces already set them apart).
	public static func showsDivider(atTab index: Int, highlighted: Set<Int>) -> Bool {
		index > 0 && !highlighted.contains(index) && !highlighted.contains(index - 1)
	}
}

/// Where a tab bar's pieces go.
public struct RiftTabBarLayout: Equatable, Sendable {
	/// The new-tab button, or `nil` when the bar has none.
	public var newTabButtonFrame: CGRect?
	/// The strip the tabs scroll in.
	public var trackFrame: CGRect
	public var tabWidth: CGFloat
	/// Each tab's frame in the bar, scrolled.
	public var tabFrames: [CGRect]
	/// The scroll offset applied, kept in range.
	public var scrollOffset: CGFloat
	public var maximumScrollOffset: CGFloat

	/// Lays out `count` tabs in `bounds`.
	///
	/// - Parameters:
	///   - leadingInset: room kept at the leading edge (for the window buttons).
	///   - trailingInset: room kept at the trailing edge.
	///   - showsNewTabButton: a 34pt (32 compact) button after the track.
	///   - fills: tabs share all the room instead of stopping at 240pt.
	///   - heldTabWidth: keep this tab width (while the pointer stays after closing a tab).
	public static func resolve(
		bounds: CGRect, count: Int, density: RiftChromeDensity, leadingInset: CGFloat = 0,
		trailingInset: CGFloat = 0, showsNewTabButton: Bool = true, fills: Bool = false,
		scrollOffset: CGFloat = 0, heldTabWidth: CGFloat? = nil
	) -> RiftTabBarLayout {
		let button = RiftTabBarMath.buttonSize(density: density, tabCount: count)
		let spacing = RiftTabBarMath.spacing(density: density)
		let midY = bounds.midY
		let trackMinX = bounds.minX + leadingInset + 2
		var trackMaxX = bounds.maxX - trailingInset - 2
		var buttonFrame: CGRect?
		if showsNewTabButton {
			let x = trackMaxX - button
			buttonFrame = CGRect(x: x, y: (midY - button / 2).rounded(), width: button, height: button)
			trackMaxX = x - spacing
		}
		let height = RiftTabBarMath.tabHeight(density: density)
		let track = CGRect(
			x: trackMinX, y: (midY - height / 2).rounded(), width: max(0, trackMaxX - trackMinX),
			height: height)
		let fitted = RiftTabBarMath.tabWidth(available: track.width, count: count, fills: fills)
		let width = heldTabWidth.map { min($0, max(fitted, RiftTabBarMath.minimumTabWidth)) } ?? fitted
		let maximum = RiftTabBarMath.maximumScrollOffset(
			tabWidth: width, count: count, trackWidth: track.width)
		let offset = min(max(scrollOffset, 0), maximum)
		let frames = RiftTabBarMath.tabFrames(
			leading: track.minX - offset, width: width, count: count,
			midY: midY, height: height)
		return RiftTabBarLayout(
			newTabButtonFrame: buttonFrame, trackFrame: track, tabWidth: width, tabFrames: frames,
			scrollOffset: offset, maximumScrollOffset: maximum)
	}
}

/// Where a tab's own pieces go.
public struct RiftTabItemLayout: Equatable, Sendable {
	public var hoverFrame: CGRect
	public var cornerRadius: CGFloat
	/// The 1 × 18 line at the tab's leading edge.
	public var dividerFrame: CGRect
	public var closeButtonFrame: CGRect
	/// The 16pt icon before the title, when the tab has one.
	public var iconFrame: CGRect?
	public var titleFrame: CGRect

	/// Lays out a tab of `size`. The close button is 22pt, centred, its glyph 5pt (4pt compact)
	/// from the trailing edge; the title runs from 12pt (3pt after an icon) to 4pt before the close
	/// button, or to 12pt from the end while the button is hidden.
	public static func resolve(
		size: CGSize, density: RiftChromeDensity, showsCloseButton: Bool, hasIcon: Bool = false
	) -> RiftTabItemLayout {
		let bounds = CGRect(origin: .zero, size: size)
		let radius = min(RiftTabBarMath.tabCornerRadius, min(size.width, size.height) / 2)
		let compactShift: CGFloat = density == .compact ? 1 : 0
		let close: CGFloat = 22
		let closeX = size.width - (12 - compactShift) - close + 7 + compactShift
		let closeFrame = CGRect(
			x: closeX, y: ((size.height - close) / 2).rounded(), width: close, height: close)
		let icon = hasIcon
			? CGRect(
				x: density == .compact ? 8 : 10, y: ((size.height - 16) / 2).rounded(), width: 16,
				height: 16)
			: nil
		let titleMinX: CGFloat = icon.map { $0.maxX + 3 } ?? 12
		let titleMaxX = showsCloseButton ? closeFrame.minX - 4 : size.width - 12
		let titleHeight: CGFloat = 16
		return RiftTabItemLayout(
			hoverFrame: bounds, cornerRadius: radius,
			dividerFrame: CGRect(x: -1, y: ((size.height - 18) / 2).rounded(), width: 1, height: 18),
			closeButtonFrame: closeFrame, iconFrame: icon,
			titleFrame: CGRect(
				x: titleMinX, y: ((size.height - titleHeight) / 2).rounded(),
				width: max(0, titleMaxX - titleMinX), height: titleHeight))
	}
}

extension RiftTabBarMath {
	/// The tab selected after closing the one at `index` of `count`: the next tab, or the one
	/// before it when it was last; `nil` when none is left.
	public static func selectionAfterClosing(index: Int, count: Int) -> Int? {
		guard count > 1 else { return nil }
		return index + 1 < count ? index : index - 1
	}
}
