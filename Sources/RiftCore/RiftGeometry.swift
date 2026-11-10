import CoreGraphics
import Foundation

/// Sizes that control how a layout is turned into frames.
public struct RiftMetrics: Equatable, Sendable {
	/// Visible thickness of a divider line, in points. Panes are separated by exactly this much.
	public var dividerThickness: CGFloat
	/// The smallest size a pane may be squeezed to by a divider.
	public var minimumPaneSize: CGSize
	/// Width of the invisible area around a divider that responds to the mouse.
	public var dividerHitThickness: CGFloat
	/// Backing scale used to round divider positions to whole pixels.
	public var displayScale: CGFloat

	public init(
		dividerThickness: CGFloat = 1,
		minimumPaneSize: CGSize = CGSize(width: 160, height: 120),
		dividerHitThickness: CGFloat = 16,
		displayScale: CGFloat = 2
	) {
		self.dividerThickness = dividerThickness
		self.minimumPaneSize = minimumPaneSize
		self.dividerHitThickness = dividerHitThickness
		self.displayScale = displayScale
	}
}

/// Where one split's divider ended up.
public struct RiftDividerPlacement: Equatable, Sendable {
	public var splitID: UUID
	public var axis: RiftAxis
	/// The stored fraction.
	public var position: Double
	/// The whole area of the split (both children plus the divider).
	public var container: CGRect
	/// The visible divider line.
	public var line: CGRect
	/// Length given to the first child after clamping.
	public var leadingLength: CGFloat
	/// Container length along the axis minus the divider thickness.
	public var available: CGFloat
	/// Minimum lengths of the two children along the axis.
	public var minLeading: CGFloat
	public var minTrailing: CGFloat

	/// The line widened to `thickness` across the axis, for hit testing.
	public func hitRect(thickness: CGFloat) -> CGRect {
		switch axis {
		case .horizontal:
			let grow = max(0, thickness - line.width) / 2
			return line.insetBy(dx: -grow, dy: 0)
		case .vertical:
			let grow = max(0, thickness - line.height) / 2
			return line.insetBy(dx: 0, dy: -grow)
		}
	}

	/// The fractions the divider may move between without violating minimum sizes.
	public var fractionRange: ClosedRange<Double> {
		guard available > 0 else { return 0.5...0.5 }
		let range = RiftDividerMath.lengthRange(
			available: available, minLeading: minLeading, minTrailing: minTrailing)
		return Double(range.lowerBound / available)...Double(range.upperBound / available)
	}
}

/// Frames for every pane and divider of a layout in a given rectangle.
public struct RiftGeometry<PaneID: Hashable & Sendable>: Sendable {
	public var bounds: CGRect
	public var paneFrames: [PaneID: CGRect]
	public var dividers: [RiftDividerPlacement]

	public init(
		bounds: CGRect, paneFrames: [PaneID: CGRect] = [:], dividers: [RiftDividerPlacement] = []
	) {
		self.bounds = bounds
		self.paneFrames = paneFrames
		self.dividers = dividers
	}

	public func pane(at point: CGPoint) -> PaneID? {
		paneFrames.first { $0.value.contains(point) }?.key
	}

	public func divider(_ splitID: UUID) -> RiftDividerPlacement? {
		dividers.first { $0.splitID == splitID }
	}
}

extension RiftLayout {
	/// The smallest length this subtree can take along `axis`.
	public func minimumLength(along axis: RiftAxis, metrics: RiftMetrics) -> CGFloat {
		switch self {
		case .pane:
			return axis == .horizontal
				? metrics.minimumPaneSize.width : metrics.minimumPaneSize.height
		case .split(let split):
			let a = split.first.minimumLength(along: axis, metrics: metrics)
			let b = split.second.minimumLength(along: axis, metrics: metrics)
			return split.axis == axis ? a + b + metrics.dividerThickness : max(a, b)
		}
	}

	/// Lays the tree out in `rect`.
	public func geometry(in rect: CGRect, metrics: RiftMetrics = RiftMetrics()) -> RiftGeometry<
		PaneID
	> {
		var geometry = RiftGeometry<PaneID>(bounds: rect)
		place(in: rect, metrics: metrics, into: &geometry)
		return geometry
	}

	private func place(
		in rect: CGRect, metrics: RiftMetrics, into geometry: inout RiftGeometry<PaneID>
	) {
		switch self {
		case .pane(let id):
			geometry.paneFrames[id] = rect
		case .split(let split):
			let thickness = metrics.dividerThickness
			let total = split.axis == .horizontal ? rect.width : rect.height
			let available = max(0, total - thickness)
			let minLeading = split.first.minimumLength(along: split.axis, metrics: metrics)
			let minTrailing = split.second.minimumLength(along: split.axis, metrics: metrics)
			let lead = RiftDividerMath.leadingLength(
				position: split.position,
				available: available,
				minLeading: minLeading,
				minTrailing: minTrailing,
				displayScale: metrics.displayScale
			)
			let trail = max(0, available - lead)
			let firstRect: CGRect
			let line: CGRect
			let secondRect: CGRect
			switch split.axis {
			case .horizontal:
				firstRect = CGRect(x: rect.minX, y: rect.minY, width: lead, height: rect.height)
				line = CGRect(
					x: rect.minX + lead, y: rect.minY, width: min(thickness, total),
					height: rect.height)
				secondRect = CGRect(x: line.maxX, y: rect.minY, width: trail, height: rect.height)
			case .vertical:
				firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lead)
				line = CGRect(
					x: rect.minX, y: rect.minY + lead, width: rect.width,
					height: min(thickness, total))
				secondRect = CGRect(x: rect.minX, y: line.maxY, width: rect.width, height: trail)
			}
			geometry.dividers.append(
				RiftDividerPlacement(
					splitID: split.id,
					axis: split.axis,
					position: split.position,
					container: rect,
					line: line,
					leadingLength: lead,
					available: available,
					minLeading: minLeading,
					minTrailing: minTrailing
				))
			split.first.place(in: firstRect, metrics: metrics, into: &geometry)
			split.second.place(in: secondRect, metrics: metrics, into: &geometry)
		}
	}
}
