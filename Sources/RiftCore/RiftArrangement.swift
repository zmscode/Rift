import CoreGraphics
import Foundation

extension RiftLayout {
    /// How many panes line up along `axis` (used to share space evenly).
    public func weight(along axis: RiftAxis) -> Int {
        switch self {
        case .pane:
            return 1
        case .split(let split):
            let a = split.first.weight(along: axis)
            let b = split.second.weight(along: axis)
            return split.axis == axis ? a + b : max(a, b)
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
        guard let divider = geometry(in: rect, metrics: metrics).divider(splitID), divider.available > 0 else {
            return nil
        }
        let range = RiftDividerMath.lengthRange(
            available: divider.available, minLeading: divider.minLeading, minTrailing: divider.minTrailing)
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

    /// The pane next to `pane` in `direction`, chosen by distance and then by how much the two overlap.
    /// With `wraps`, continues from the opposite side of the layout when nothing lies that way.
    public func neighbor(
        of pane: PaneID,
        toward direction: RiftDirection,
        in rect: CGRect,
        metrics: RiftMetrics = RiftMetrics(),
        wraps: Bool = false
    ) -> PaneID? {
        let geometry = geometry(in: rect, metrics: metrics)
        guard let from = geometry.paneFrames[pane] else { return nil }
        let horizontal = direction == .left || direction == .right

        func overlap(_ frame: CGRect) -> CGFloat {
            horizontal
                ? min(from.maxY, frame.maxY) - max(from.minY, frame.minY)
                : min(from.maxX, frame.maxX) - max(from.minX, frame.minX)
        }
        func gap(_ frame: CGRect) -> CGFloat {
            switch direction {
            case .right: frame.minX - from.maxX
            case .left: from.minX - frame.maxX
            case .down: frame.minY - from.maxY
            case .up: from.minY - frame.maxY
            }
        }

        var best: (id: PaneID, gap: CGFloat, overlap: CGFloat)?
        for id in paneIDs where id != pane {
            guard let frame = geometry.paneFrames[id] else { continue }
            let shared = overlap(frame), distance = gap(frame)
            guard shared > 0, distance >= -0.5 else { continue }
            if let current = best {
                if distance < current.gap - 0.5 || (abs(distance - current.gap) <= 0.5 && shared > current.overlap) {
                    best = (id, distance, shared)
                }
            } else {
                best = (id, distance, shared)
            }
        }
        if let best { return best.id }
        guard wraps else { return nil }

        // Wrap: the overlapping pane farthest in the opposite direction.
        var wrapped: (id: PaneID, key: CGFloat)?
        for id in paneIDs where id != pane {
            guard let frame = geometry.paneFrames[id], overlap(frame) > 0 else { continue }
            let key: CGFloat = switch direction {
            case .right: -frame.minX
            case .left: frame.maxX
            case .down: -frame.minY
            case .up: frame.maxY
            }
            if wrapped == nil || key > wrapped!.key { wrapped = (id, key) }
        }
        return wrapped?.id
    }
}
