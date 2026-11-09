import CoreGraphics

extension RiftDropZone {
    /// Width of an edge band for a pane `length` long: `preferred` points,
    /// but never less than a quarter or more than a third of the pane.
    public static func bandLength(for length: CGFloat, preferred: CGFloat = 80) -> CGFloat {
        let quarter = length / 4
        return quarter >= preferred ? quarter : min(length / 3, preferred)
    }

    /// Classifies `point` (same coordinate space as `frame`, y down) into a drop zone.
    /// Left/right bands are checked first, so corners resolve to a side.
    public static func classify(_ point: CGPoint, in frame: CGRect, preferredBand: CGFloat = 80) -> RiftDropZone {
        let x = point.x - frame.minX
        let y = point.y - frame.minY
        let bandX = bandLength(for: frame.width, preferred: preferredBand)
        let bandY = bandLength(for: frame.height, preferred: preferredBand)
        if x < bandX { return .left }
        if x > frame.width - bandX { return .right }
        if y < bandY { return .top }
        if y > frame.height - bandY { return .bottom }
        return .center
    }

    /// The edge of `frame` nearest to `point`.
    public static func nearestEdge(to point: CGPoint, in frame: CGRect) -> RiftEdge {
        let distances: [(RiftEdge, CGFloat)] = [
            (.left, point.x - frame.minX),
            (.right, frame.maxX - point.x),
            (.top, point.y - frame.minY),
            (.bottom, frame.maxY - point.y),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// The highlight rectangle for this zone: the half of `frame` the pane will occupy, inset by `inset`.
    public func indicatorRect(in frame: CGRect, inset: CGFloat = 4) -> CGRect {
        let halfWidth = max(0, frame.width / 2 - inset)
        let halfHeight = max(0, frame.height / 2 - inset)
        let fullWidth = max(0, frame.width - inset * 2)
        let fullHeight = max(0, frame.height - inset * 2)
        switch self {
        case .center:
            return CGRect(x: frame.minX + inset, y: frame.minY + inset, width: fullWidth, height: fullHeight)
        case .left:
            return CGRect(x: frame.minX + inset, y: frame.minY + inset, width: halfWidth, height: fullHeight)
        case .right:
            return CGRect(x: frame.midX, y: frame.minY + inset, width: halfWidth, height: fullHeight)
        case .top:
            return CGRect(x: frame.minX + inset, y: frame.minY + inset, width: fullWidth, height: halfHeight)
        case .bottom:
            return CGRect(x: frame.minX + inset, y: frame.midY, width: fullWidth, height: halfHeight)
        }
    }
}
