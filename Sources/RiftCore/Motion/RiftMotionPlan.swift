import CoreGraphics
import Foundation

/// How panes appear in and disappear from the layout.
public enum RiftPaneTransitionStyle: Hashable, Sendable {
	/// Panes scale up from (or down to) a smaller size while fading.
	case popIn(RiftPanePopIn)
	/// Panes grow out of (or shrink into) the edge they were split from, fading with their size.
	case edgeGrowth
}

/// Smoothstep: `u² (3 − 2u)` for `u` clamped to 0…1.
@inlinable
func riftSmoothstep(_ u: Double) -> Double {
	let u = min(max(u, 0), 1)
	return u * u * (3 - 2 * u)
}

/// Panes fading because they are being hidden (for example behind a zoomed pane) or revealed.
public struct RiftVisibilityFade: Hashable, Sendable {
	public enum Direction: Hashable, Sendable { case hiding, revealing }

	public var direction: Direction
	/// How far through the fade a motion that this one interrupts had got (0…1).
	public var phaseStart: Double
	/// The opacity the panes had when this fade began.
	public var startOpacity: Double

	public init(direction: Direction, phaseStart: Double = 0, startOpacity: Double? = nil) {
		self.direction = direction
		self.phaseStart = phaseStart
		self.startOpacity = startOpacity ?? (direction == .hiding ? 1 : 0)
	}

	/// The panes' opacity at `progress` (0…1) through the motion.
	///
	/// The fade picks up from `phaseStart`. Hiding panes fade out over the first half of the
	/// phase on a smoothstep and stay hidden after it; revealing panes hold their start opacity
	/// for the first half, then fade in on a smoothstep.
	public func opacity(progress: Double) -> Double {
		let t = min(max(progress, 0), 1)
		let start = min(max(phaseStart, 0), 1)
		let phase = t + (1 - t) * start
		let from = min(max(startOpacity, 0), 1)
		switch direction {
		case .revealing:
			guard phase > 0.5 else { return from }
			return from + (1 - from) * riftSmoothstep(2 * (phase - 0.5))
		case .hiding:
			guard phase < 0.5 else { return 0 }
			return from * (1 - riftSmoothstep(2 * phase))
		}
	}
}

/// A pane growing out of, or shrinking into, one of its edges.
public struct RiftGrowthTransition: Hashable, Sendable {
	public enum Direction: Hashable, Sendable { case insertion, removal }

	/// Panes are never drawn shorter than this along the growth axis (unless their full length is).
	public static let minimumExtent: CGFloat = 32

	/// The edge the pane is anchored to while it grows or shrinks.
	public var edge: RiftEdge
	public var startRawFrame: CGRect
	public var endRawFrame: CGRect
	/// The pane's length along the growth axis when fully shown.
	public var fullExtent: CGFloat
	public var startOpacity: Double
	/// The spatial progress (see `spatialOpacity`) when the transition began.
	public var startSpatialOpacity: Double

	public init(
		edge: RiftEdge, startRawFrame: CGRect, endRawFrame: CGRect, fullExtent: CGFloat,
		startOpacity: Double, startSpatialOpacity: Double
	) {
		self.edge = edge
		self.startRawFrame = startRawFrame
		self.endRawFrame = endRawFrame
		self.fullExtent = fullExtent
		self.startOpacity = startOpacity
		self.startSpatialOpacity = startSpatialOpacity
	}

	/// A pane growing out of `edge` of `frame` (its final frame).
	public static func inserting(_ frame: CGRect, from edge: RiftEdge) -> Self {
		Self(
			edge: edge, startRawFrame: frame.rift_collapsed(toward: edge), endRawFrame: frame,
			fullExtent: frame.rift_extent(along: edge), startOpacity: 0, startSpatialOpacity: 0)
	}

	/// A pane shrinking into `edge` of `frame` (its current frame).
	public static func removing(_ frame: CGRect, into edge: RiftEdge) -> Self {
		Self(
			edge: edge, startRawFrame: frame, endRawFrame: frame.rift_collapsed(toward: edge),
			fullExtent: frame.rift_extent(along: edge), startOpacity: 1, startSpatialOpacity: 1)
	}

	/// The frame the layout gives the pane at `progress`.
	public func rawFrame(progress: Double) -> CGRect {
		startRawFrame.rift_interpolated(to: endRawFrame, progress: progress)
	}

	/// The frame drawn at `progress`: the raw frame, but at least `minimumExtent` long (or the full
	/// length, if shorter) and anchored to `edge`.
	public func displayFrame(progress: Double) -> CGRect {
		let raw = rawFrame(progress: progress)
		let extent = max(min(fullExtent, Self.minimumExtent), raw.rift_extent(along: edge))
		return raw.rift_anchored(to: edge, extent: extent)
	}

	/// How much of the pane is shown, eased: a smoothstep of the raw length past the first
	/// `minimumExtent` points, over the rest of the full length.
	public func spatialOpacity(progress: Double) -> Double {
		guard fullExtent > 0 else { return 0 }
		let length = rawFrame(progress: progress).rift_extent(along: edge)
		let floor = Self.minimumExtent
		let fraction =
			fullExtent <= floor ? length / fullExtent : (length - floor) / (fullExtent - floor)
		return riftSmoothstep(Double(fraction))
	}

	/// The pane's opacity at `progress`. It follows the spatial progress, continuing from
	/// `startOpacity`: down to 0 for a removal, up to 1 for an insertion.
	public func opacity(progress: Double, direction: Direction) -> Double {
		let spatial = spatialOpacity(progress: progress)
		switch direction {
		case .removal:
			guard startSpatialOpacity > 1e-9 else { return 0 }
			return min(max(spatial / startSpatialOpacity, 0), 1) * startOpacity
		case .insertion:
			guard 1 - startSpatialOpacity > 1e-9 else { return 1 }
			let u = min(max((spatial - startSpatialOpacity) / (1 - startSpatialOpacity), 0), 1)
			return startOpacity + u * (1 - startOpacity)
		}
	}
}

/// A pane popping in or out.
public struct RiftPopState: Hashable, Sendable {
	public enum Direction: Hashable, Sendable { case entering, leaving }

	public var direction: Direction
	public var startScale: Double
	public var startOpacity: Double

	public init(direction: Direction, startScale: Double? = nil, startOpacity: Double? = nil) {
		self.direction = direction
		self.startScale = startScale ?? (direction == .entering ? .nan : 1)
		self.startOpacity = startOpacity ?? (direction == .entering ? 0 : 1)
	}

	/// The pane's scale `elapsed` seconds in.
	public func scale(elapsed: Double, style: RiftPanePopIn) -> Double {
		switch direction {
		case .entering:
			let from = startScale.isNaN ? style.scale : startScale
			return from + (1 - from) * style.entry.progress(elapsed: elapsed)
		case .leaving:
			return startScale + (style.scale - startScale) * style.exit.progress(elapsed: elapsed)
		}
	}

	/// The pane's opacity `elapsed` seconds in.
	public func opacity(elapsed: Double, style: RiftPanePopIn) -> Double {
		switch direction {
		case .entering:
			let p = min(max(style.fadeIn.progress(elapsed: elapsed), 0), 1)
			return startOpacity + (1 - startOpacity) * p
		case .leaving:
			let p = min(max(style.fadeOut.progress(elapsed: elapsed), 0), 1)
			return startOpacity * (1 - p)
		}
	}

	/// How long the pop runs.
	public func duration(style: RiftPanePopIn) -> Double {
		switch direction {
		case .entering: max(style.entry.duration, style.fadeIn.duration)
		case .leaving: max(style.exit.duration, style.fadeOut.duration)
		}
	}
}

/// Divider line opacities during a layout motion: each line goes from its opacity at the start to
/// its opacity at the end, and a line missing at either end counts as 0 there (so new lines fade in
/// and removed lines fade out).
public func riftDividerOpacities(
	from start: [UUID: Double], to end: [UUID: Double], progress: Double
) -> [UUID: Double] {
	var result: [UUID: Double] = [:]
	for id in Set(start.keys).union(end.keys) {
		let a = start[id] ?? 0
		let b = end[id] ?? 0
		if a == 0 && b == 0 { continue }
		result[id] = a + progress * (b - a)
	}
	return result
}

extension CGRect {
	/// The rect `p` of the way from this one to `other` (sizes never go below zero).
	public func rift_interpolated(to other: CGRect, progress p: Double) -> CGRect {
		let t = CGFloat(p)
		return CGRect(
			x: minX + (other.minX - minX) * t,
			y: minY + (other.minY - minY) * t,
			width: max(0, width + (other.width - width) * t),
			height: max(0, height + (other.height - height) * t))
	}

	/// Length across `edge`: width for left and right, height for top and bottom.
	public func rift_extent(along edge: RiftEdge) -> CGFloat {
		switch edge {
		case .left, .right: width
		case .top, .bottom: height
		}
	}

	/// This rect squashed to zero length against `edge` (y grows downward).
	public func rift_collapsed(toward edge: RiftEdge) -> CGRect {
		rift_anchored(to: edge, extent: 0)
	}

	/// A rect `extent` long across `edge`, flush with that edge of this rect (y grows downward).
	public func rift_anchored(to edge: RiftEdge, extent: CGFloat) -> CGRect {
		let e = max(extent, 0)
		switch edge {
		case .left: return CGRect(x: minX, y: minY, width: e, height: height)
		case .right: return CGRect(x: maxX - e, y: minY, width: e, height: height)
		case .top: return CGRect(x: minX, y: minY, width: width, height: e)
		case .bottom: return CGRect(x: minX, y: maxY - e, width: width, height: e)
		}
	}
}
