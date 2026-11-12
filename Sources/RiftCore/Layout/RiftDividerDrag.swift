import CoreGraphics
import Foundation

/// Controls the snap-to-center behaviour while dragging a divider.
public struct RiftSnapConfiguration: Equatable, Sendable {
	public var isEnabled: Bool
	/// Distance from the center (points) at which an unsnapped divider snaps.
	public var radius: CGFloat
	/// Distance a snapped divider must travel to break free. Larger than `radius` so it doesn't flicker.
	public var holdRadius: CGFloat
	/// Splits whose half-length is at or below this never snap.
	public var minimumHalfLength: CGFloat
	/// How close to the exact center the clamped position must be for a snap to be allowed.
	public var tolerance: CGFloat

	public init(
		isEnabled: Bool = true,
		radius: CGFloat = 10,
		holdRadius: CGFloat = 16,
		minimumHalfLength: CGFloat = 10,
		tolerance: CGFloat = 0.5
	) {
		self.isEnabled = isEnabled
		self.radius = radius
		self.holdRadius = holdRadius
		self.minimumHalfLength = minimumHalfLength
		self.tolerance = tolerance
	}
}

/// A divider position produced by a drag or keyboard adjustment.
public struct RiftDividerUpdate: Equatable, Sendable {
	public var splitID: UUID
	public var position: Double
	public var isSnappedToCenter: Bool

	public init(splitID: UUID, position: Double, isSnappedToCenter: Bool = false) {
		self.splitID = splitID
		self.position = position
		self.isSnappedToCenter = isSnappedToCenter
	}
}

public enum RiftDividerMath {
	/// The leading lengths a divider may take without squeezing either side below its minimum.
	/// When both minimums can't fit, the space is shared in proportion to them.
	public static func lengthRange(available: CGFloat, minLeading: CGFloat, minTrailing: CGFloat)
		-> ClosedRange<CGFloat>
	{
		guard available > 0 else { return 0...0 }
		let a = max(0, minLeading)
		let b = max(0, minTrailing)
		if a + b <= available { return a...(available - b) }
		let share = a + b > 0 ? available * a / (a + b) : available / 2
		return share...share
	}

	/// The pixel-aligned leading length for a stored fraction.
	public static func leadingLength(
		position: Double,
		available: CGFloat,
		minLeading: CGFloat,
		minTrailing: CGFloat,
		displayScale: CGFloat
	) -> CGFloat {
		guard available > 0 else { return 0 }
		let fraction = position.isFinite ? CGFloat(min(max(position, 0), 1)) : 0.5
		let range = lengthRange(
			available: available, minLeading: minLeading, minTrailing: minTrailing)
		var lead = min(max(fraction * available, range.lowerBound), range.upperBound)
		if displayScale > 0 { lead = (lead * displayScale).rounded() / displayScale }
		return min(max(lead, 0), available)
	}

	/// Converts a dragged leading length into a fraction, applying snap-to-center and minimum sizes.
	///
	/// - Parameter wasCentered: whether this divider was snapped on the previous event (enables the hold radius).
	public static func dragPosition(
		leadingOffset offset: CGFloat,
		available: CGFloat,
		minLeading: CGFloat,
		minTrailing: CGFloat,
		wasCentered: Bool,
		snap: RiftSnapConfiguration
	) -> (position: Double, isSnappedToCenter: Bool) {
		guard available > 0 else { return (0.5, false) }
		let range = lengthRange(
			available: available, minLeading: minLeading, minTrailing: minTrailing)
		let half = available / 2
		if snap.isEnabled, half > snap.minimumHalfLength {
			let radius = wasCentered ? snap.holdRadius : snap.radius
			if abs(offset - half) <= radius {
				let reachable = min(max(half, range.lowerBound), range.upperBound)
				if abs(reachable - half) <= snap.tolerance { return (0.5, true) }
			}
		}
		let lead = min(max(offset, range.lowerBound), range.upperBound)
		return (Double(lead / available), false)
	}
}

/// The dividers under a point. Two dividers on different axes mean the pointer is on an intersection.
public struct RiftDividerHit: Equatable, Sendable {
	public var dividers: [RiftDividerPlacement]
	public init(dividers: [RiftDividerPlacement]) { self.dividers = dividers }
	public var isIntersection: Bool { Set(dividers.map(\.axis)).count > 1 }
	public var axis: RiftAxis? { isIntersection ? nil : dividers.first?.axis }
	/// Where the two divider lines cross, for an intersection.
	public var crossingPoint: CGPoint? {
		guard let v = dividers.first(where: { $0.axis == .horizontal }),
			let h = dividers.first(where: { $0.axis == .vertical })
		else { return nil }
		return CGPoint(x: v.line.midX, y: h.line.midY)
	}
}

extension RiftGeometry {
	/// The closest divider per axis whose hit area contains `point`.
	public func dividerHit(at point: CGPoint, hitThickness: CGFloat) -> RiftDividerHit? {
		var best: [RiftAxis: (placement: RiftDividerPlacement, distance: CGFloat)] = [:]
		for divider in dividers where divider.hitRect(thickness: hitThickness).contains(point) {
			let distance =
				divider.axis == .horizontal
				? abs(point.x - divider.line.midX)
				: abs(point.y - divider.line.midY)
			if let current = best[divider.axis], current.distance <= distance { continue }
			best[divider.axis] = (divider, distance)
		}
		let ordered = [RiftAxis.horizontal, .vertical].compactMap { best[$0]?.placement }
		return ordered.isEmpty ? nil : RiftDividerHit(dividers: ordered)
	}
}

/// State for one divider drag. Several dividers move together when an intersection is grabbed.
public struct RiftDividerDrag: Sendable {
	public struct Handle: Equatable, Sendable {
		public var splitID: UUID
		public var axis: RiftAxis
		/// Pointer distance from the line's center at mouse-down, kept constant while dragging.
		public var grabOffset: CGFloat
	}

	public private(set) var handles: [Handle]
	public private(set) var centeredSplitIDs: Set<UUID>

	public init(hit: RiftDividerHit, pointer: CGPoint) {
		handles = hit.dividers.map { divider in
			let offset =
				divider.axis == .horizontal
				? pointer.x - divider.line.midX
				: pointer.y - divider.line.midY
			return Handle(splitID: divider.splitID, axis: divider.axis, grabOffset: offset)
		}
		// Dividers that already sit in the middle start snapped, so grabbing one doesn't buzz.
		centeredSplitIDs = Set(hit.dividers.filter { abs($0.position - 0.5) < 1e-9 }.map(\.splitID))
	}

	/// Computes new positions for `pointer`. `didSnap` is true when a divider newly snapped to center.
	public mutating func update<PaneID>(
		pointer: CGPoint,
		geometry: RiftGeometry<PaneID>,
		metrics: RiftMetrics,
		snap: RiftSnapConfiguration = RiftSnapConfiguration()
	) -> (updates: [RiftDividerUpdate], didSnap: Bool) {
		var updates: [RiftDividerUpdate] = []
		for handle in handles {
			guard let divider = geometry.divider(handle.splitID) else { continue }
			let coordinate = handle.axis == .horizontal ? pointer.x : pointer.y
			let origin =
				handle.axis == .horizontal ? divider.container.minX : divider.container.minY
			let offset = coordinate - handle.grabOffset - origin - metrics.dividerThickness / 2
			let result = RiftDividerMath.dragPosition(
				leadingOffset: offset,
				available: divider.available,
				minLeading: divider.minLeading,
				minTrailing: divider.minTrailing,
				wasCentered: centeredSplitIDs.contains(handle.splitID),
				snap: snap
			)
			updates.append(
				RiftDividerUpdate(
					splitID: handle.splitID, position: result.position,
					isSnappedToCenter: result.isSnappedToCenter))
		}
		let nowCentered = Set(updates.filter(\.isSnappedToCenter).map(\.splitID))
		let didSnap = !nowCentered.subtracting(centeredSplitIDs).isEmpty
		centeredSplitIDs = nowCentered
		return (updates, didSnap)
	}
}
