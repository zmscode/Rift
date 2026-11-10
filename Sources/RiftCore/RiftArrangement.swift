import CoreGraphics
import Foundation

extension RiftLayout {
	/// How many slots this subtree takes along `axis` when sharing space evenly: a split on the same
	/// axis adds up its children; a pane, or a split across the axis, counts as one.
	public func weight(along axis: RiftAxis) -> Int {
		switch self {
		case .split(let split) where split.axis == axis:
			return split.first.weight(along: axis) + split.second.weight(along: axis)
		default:
			return 1
		}
	}

	/// Resets divider positions so panes share space evenly, leaving splits in `keeping` untouched.
	public func balanced(keeping: Set<UUID> = []) -> RiftLayout {
		guard case .split(var split) = self else { return self }
		split.first = split.first.balanced(keeping: keeping)
		split.second = split.second.balanced(keeping: keeping)
		if !keeping.contains(split.id) {
			let a = Double(split.first.weight(along: split.axis))
			let b = Double(split.second.weight(along: split.axis))
			split.position = a / (a + b)
		}
		return .split(split)
	}

	/// The deepest split whose divider runs along `edge` of `pane`.
	public func splitID(bordering pane: PaneID, on edge: RiftEdge) -> UUID? {
		guard let path = path(to: pane) else { return nil }
		for step in path.reversed() where step.split.axis == edge.axis {
			// A pane in the first child touches its split's divider on its trailing edge.
			if edge.isLeading ? !step.inFirst : step.inFirst { return step.split.id }
		}
		return nil
	}

	/// Moves a divider by `delta` points (positive = toward trailing), honouring minimum sizes.
	public func movingDivider(
		_ splitID: UUID,
		by delta: CGFloat,
		in rect: CGRect,
		metrics: RiftMetrics = RiftMetrics()
	) -> RiftLayout? {
		guard let divider = geometry(in: rect, metrics: metrics).divider(splitID),
			divider.available > 0
		else {
			return nil
		}
		let range = RiftDividerMath.lengthRange(
			available: divider.available, minLeading: divider.minLeading,
			minTrailing: divider.minTrailing)
		let lead = min(max(divider.leadingLength + delta, range.lowerBound), range.upperBound)
		return settingPosition(Double(lead / divider.available), ofSplit: splitID)
	}

	/// Grows `pane` toward `direction` by `points`, by moving the nearest divider on that side.
	public func resizing(
		_ pane: PaneID,
		toward direction: RiftDirection,
		by points: CGFloat,
		in rect: CGRect,
		metrics: RiftMetrics = RiftMetrics()
	) -> RiftLayout? {
		let edge = direction.edge
		guard let id = splitID(bordering: pane, on: edge) else { return nil }
		return movingDivider(id, by: edge.isLeading ? -points : points, in: rect, metrics: metrics)
	}

	/// Rect of every pane in unit space: the root is (0, 0, 1, 1), y grows downward, and each split
	/// divides its rect by `position` with no room for dividers or minimum sizes.
	public func unitRects() -> [PaneID: CGRect] {
		var result: [PaneID: CGRect] = [:]
		func visit(_ node: RiftLayout, _ rect: CGRect) {
			switch node {
			case .pane(let id):
				result[id] = rect
			case .split(let split):
				let r = CGFloat(split.position)
				switch split.axis {
				case .horizontal:
					visit(
						split.first,
						CGRect(
							x: rect.minX, y: rect.minY, width: r * rect.width, height: rect.height))
					visit(
						split.second,
						CGRect(
							x: rect.minX + r * rect.width, y: rect.minY,
							width: (1 - r) * rect.width, height: rect.height))
				case .vertical:
					visit(
						split.first,
						CGRect(
							x: rect.minX, y: rect.minY, width: rect.width, height: r * rect.height))
					visit(
						split.second,
						CGRect(
							x: rect.minX, y: rect.minY + r * rect.height, width: rect.width,
							height: (1 - r) * rect.height))
				}
			}
		}
		visit(self, CGRect(x: 0, y: 0, width: 1, height: 1))
		return result
	}

	/// The pane next to `pane` in `direction`.
	///
	/// Works in unit space (see `unitRects()`). A candidate must lie wholly past the matching edge
	/// of `pane`; it doesn't need to overlap it. The candidate whose top-left corner is closest to
	/// `pane`'s top-left corner wins, and ties go to the pane earlier in layout order. With
	/// `wraps`, when nothing lies that way the search runs again from one whole layout beyond the
	/// opposite edge.
	public func neighbor(of pane: PaneID, toward direction: RiftDirection, wraps: Bool = false)
		-> PaneID?
	{
		let rects = unitRects()
		guard let from = rects[pane] else { return nil }
		let order = paneIDs
		func search(_ probe: CGRect) -> PaneID? {
			var best: (id: PaneID, distance: CGFloat)?
			for id in order where id != pane {
				guard let leaf = rects[id] else { continue }
				let isCandidate =
					switch direction {
					case .left: leaf.maxX <= probe.minX
					case .right: leaf.minX >= probe.maxX
					case .up: leaf.maxY <= probe.minY
					case .down: leaf.minY >= probe.maxY
					}
				guard isCandidate else { continue }
				let dx = leaf.minX - probe.minX
				let dy = leaf.minY - probe.minY
				let distance = dx * dx + dy * dy
				if best == nil || distance < best!.distance { best = (id, distance) }
			}
			return best?.id
		}
		if let found = search(from) { return found }
		guard wraps else { return nil }
		let shifted: CGRect =
			switch direction {
			case .left: from.offsetBy(dx: 1, dy: 0)
			case .right: from.offsetBy(dx: -1, dy: 0)
			case .up: from.offsetBy(dx: 0, dy: 1)
			case .down: from.offsetBy(dx: 0, dy: -1)
			}
		return search(shifted)
	}

	/// The same as `neighbor(of:toward:wraps:)`; the rect and metrics are not used, because the
	/// search runs in unit space.
	public func neighbor(
		of pane: PaneID,
		toward direction: RiftDirection,
		in rect: CGRect,
		metrics: RiftMetrics = RiftMetrics(),
		wraps: Bool = false
	) -> PaneID? {
		neighbor(of: pane, toward: direction, wraps: wraps)
	}
}
