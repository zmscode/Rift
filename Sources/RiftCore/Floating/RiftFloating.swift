import CoreGraphics
import Foundation

/// A floating layer: its own split layout of panes in a window-like card above the tiled layout.
///
/// Its bounds are stored as a unit rectangle (fractions of the floating area), so it keeps its
/// place as the container resizes.
public struct RiftFloatingLayer<PaneID: Hashable & Sendable>: Equatable, Sendable, Identifiable {
	public var id: UUID
	/// The layer's frame as fractions of the floating area (0…1 on each axis).
	public var bounds: CGRect
	public var layout: RiftLayout<PaneID>
	/// Minimised layers are hidden and shown as capsules along the bottom of the layout.
	public var isMinimised: Bool

	public init(
		id: UUID = UUID(), bounds: CGRect, layout: RiftLayout<PaneID>, isMinimised: Bool = false
	) {
		self.id = id
		self.bounds = bounds
		self.layout = layout
		self.isMinimised = isMinimised
	}
}

extension RiftFloatingLayer: Codable where PaneID: Codable {}

/// Which edges a floating layer's resize handle drags.
public struct RiftResizeEdges: OptionSet, Sendable, Hashable {
	public let rawValue: Int
	public init(rawValue: Int) { self.rawValue = rawValue }

	public static let left = RiftResizeEdges(rawValue: 1 << 0)
	public static let right = RiftResizeEdges(rawValue: 1 << 1)
	public static let top = RiftResizeEdges(rawValue: 1 << 2)
	public static let bottom = RiftResizeEdges(rawValue: 1 << 3)
}

/// How far past each side of the floating area a layer may be pulled (see `moved`).
public struct RiftFloatingRoom: Sendable, Hashable {
	public var left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat

	public init(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
		self.left = left
		self.right = right
		self.top = top
		self.bottom = bottom
	}

	public static func all(_ room: CGFloat) -> Self {
		Self(left: room, right: room, top: room, bottom: room)
	}
}

/// A floating layer's shadow: resting, or lifted while it is moved or resized.
public struct RiftFloatingShadow: Sendable, Hashable {
	public var opacity: Float
	public var radius: CGFloat
	public var y: CGFloat

	/// Opacity 0.14, blur 10, 3pt down.
	public static let resting = RiftFloatingShadow(opacity: 0.14, radius: 10, y: 3)
	/// Opacity 0.28, blur 40, 20pt down.
	public static let active = RiftFloatingShadow(opacity: 0.28, radius: 40, y: 20)
}

/// The numbers behind floating layers: where new ones go, how they move and resize.
public enum RiftFloatingGeometry {
	/// The most a layer travels past an edge of the floating area.
	public static let maximumOvershoot: CGFloat = 24
	/// How quickly the overshoot resistance builds: `1 − e^(−distance / 120)`.
	public static let overshootScale: CGFloat = 120
	/// Edges within this distance (at most half the free span) snap.
	public static let snapDistance: CGFloat = 10
	/// New layers are at least this big (unless the area is smaller).
	public static let minimumSize = CGSize(width: 240, height: 150)
	/// A new layer that would land within this distance of another's origin is moved along.
	public static let cascadeDistance: CGFloat = 14
	/// How far each cascaded layer moves.
	public static let cascadeOffset: CGFloat = 28

	/// Where a new floating layer goes: the source pane's size, but no more than 55% of the
	/// area's width and 60% of its height, at least 240 × 150, centred in the area. While it
	/// would land within 14pt of an existing layer's origin it moves 28pt down and right. It is
	/// kept inside the area.
	public static func newBounds(for source: CGSize?, in area: CGRect, existing: [CGRect]) -> CGRect
	{
		guard area.width > 0, area.height > 0 else { return .zero }
		let sourceSize = source ?? area.size
		let width = min(
			max(min(sourceSize.width, area.width * 0.55), minimumSize.width), area.width)
		let height = min(
			max(min(sourceSize.height, area.height * 0.6), minimumSize.height), area.height)
		var frame = CGRect(
			x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
		for _ in existing {
			guard
				existing.contains(where: {
					abs($0.minX - frame.minX) < cascadeDistance
						&& abs($0.minY - frame.minY) < cascadeDistance
				})
			else { break }
			frame = frame.offsetBy(dx: cascadeOffset, dy: cascadeOffset)
		}
		frame.origin.x = min(max(frame.minX, area.minX), area.maxX - width)
		frame.origin.y = min(max(frame.minY, area.minY), area.maxY - height)
		return frame
	}

	/// One axis of a move: `value` kept between `lower` and `upper`, pulled at most
	/// min(room, 24)pt past either with resistance `1 − e^(−overshoot / 120)`; with `snaps`, a
	/// value within min(span / 2, 10)pt of an end snaps to the nearer end.
	public static func axis(
		_ value: CGFloat, lower: CGFloat, upper: CGFloat, roomBelow: CGFloat, roomAbove: CGFloat,
		snaps: Bool
	) -> CGFloat {
		let upper = max(upper, lower)
		if value < lower {
			let travel = min(roomBelow, maximumOvershoot)
			return lower - travel * (1 - exp(-(lower - value) / overshootScale))
		}
		if value > upper {
			let travel = min(roomAbove, maximumOvershoot)
			return upper + travel * (1 - exp(-(value - upper) / overshootScale))
		}
		guard snaps else { return value }
		let threshold = min((upper - lower) / 2, snapDistance)
		let below = value - lower
		let above = upper - value
		if below <= threshold || above <= threshold { return below <= above ? lower : upper }
		return value
	}

	/// A layer moved from `start` by `delta`, kept to `area` (see `axis`).
	public static func moved(
		_ start: CGRect, by delta: CGSize, in area: CGRect, room: RiftFloatingRoom = .all(24),
		snaps: Bool = true
	) -> CGRect {
		let x = axis(
			start.minX + delta.width, lower: area.minX, upper: area.maxX - start.width,
			roomBelow: room.left, roomAbove: room.right, snaps: snaps)
		let y = axis(
			start.minY + delta.height, lower: area.minY, upper: area.maxY - start.height,
			roomBelow: room.top, roomAbove: room.bottom, snaps: snaps)
		return CGRect(x: x, y: y, width: start.width, height: start.height)
	}

	/// A layer resized from `start` by dragging `edges` by `delta`: the dragged edges move, kept
	/// inside `area`, and the size never goes under `minimum` (or the area). Edges within 10pt of
	/// the area's edges snap to them.
	public static func resized(
		_ start: CGRect, edges: RiftResizeEdges, by delta: CGSize, in area: CGRect,
		minimum: CGSize = minimumSize, snaps: Bool = true
	) -> CGRect {
		let minWidth = min(minimum.width, area.width)
		let minHeight = min(minimum.height, area.height)
		func snapped(_ v: CGFloat, to edge: CGFloat) -> CGFloat {
			snaps && abs(v - edge) <= snapDistance ? edge : v
		}
		var minX = start.minX
		var maxX = start.maxX
		var minY = start.minY
		var maxY = start.maxY
		if edges.contains(.left) {
			minX = snapped(
				min(max(start.minX + delta.width, area.minX), maxX - minWidth), to: area.minX)
		}
		if edges.contains(.right) {
			maxX = snapped(
				max(min(start.maxX + delta.width, area.maxX), minX + minWidth), to: area.maxX)
		}
		if edges.contains(.top) {
			minY = snapped(
				min(max(start.minY + delta.height, area.minY), maxY - minHeight), to: area.minY)
		}
		if edges.contains(.bottom) {
			maxY = snapped(
				max(min(start.maxY + delta.height, area.maxY), minY + minHeight), to: area.maxY)
		}
		return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
	}

	/// A frame as fractions of `area`.
	public static func unit(_ frame: CGRect, in area: CGRect) -> CGRect {
		guard area.width > 0, area.height > 0 else { return .zero }
		return CGRect(
			x: (frame.minX - area.minX) / area.width, y: (frame.minY - area.minY) / area.height,
			width: frame.width / area.width, height: frame.height / area.height)
	}

	/// A unit rectangle placed in `area`, rounded to whole points.
	public static func absolute(_ unit: CGRect, in area: CGRect) -> CGRect {
		CGRect(
			x: (area.minX + unit.minX * area.width).rounded(),
			y: (area.minY + unit.minY * area.height).rounded(),
			width: (unit.width * area.width).rounded(),
			height: (unit.height * area.height).rounded())
	}

	/// The frames of minimised layers' capsules: centred along the bottom of `area`, 28pt tall,
	/// 8pt apart and 8pt up from the edge, each as wide as its title (between 96 and 200pt).
	public static func capsuleFrames(widths: [CGFloat], in area: CGRect) -> [CGRect] {
		let sizes = widths.map { min(max($0, 96), 200) }
		let total = sizes.reduce(0, +) + CGFloat(max(sizes.count - 1, 0)) * 8
		var x = (area.midX - total / 2).rounded()
		return sizes.map { width in
			defer { x += width + 8 }
			return CGRect(x: x, y: area.maxY - 8 - 28, width: width, height: 28)
		}
	}
}
