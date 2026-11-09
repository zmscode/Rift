import CoreGraphics
import Foundation

/// The direction in which a split arranges its two children.
///
/// All Rift geometry uses a top-left origin (y grows downward), matching a flipped `NSView`.
public enum RiftAxis: String, Codable, Sendable, Hashable, CaseIterable {
    /// Children sit side by side; the divider line is vertical.
    case horizontal
    /// Children are stacked; the divider line is horizontal.
    case vertical

    public var cross: RiftAxis { self == .horizontal ? .vertical : .horizontal }
}

/// An edge of a pane or layout.
public enum RiftEdge: String, Codable, Sendable, Hashable, CaseIterable {
    case left, right, top, bottom

    /// The split axis that places content on this edge.
    public var axis: RiftAxis { (self == .left || self == .right) ? .horizontal : .vertical }

    /// Content placed on a leading edge becomes the split's first child.
    public var isLeading: Bool { self == .left || self == .top }

    public var opposite: RiftEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }
}

/// A direction for focus navigation and keyboard resizing.
public enum RiftDirection: String, Codable, Sendable, Hashable, CaseIterable {
    case left, right, up, down

    public var edge: RiftEdge {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .top
        case .down: .bottom
        }
    }
}

/// Where a dragged pane lands relative to the pane under the pointer.
public enum RiftDropZone: String, Codable, Sendable, Hashable, CaseIterable {
    /// Swap with the target pane.
    case center
    case left, right, top, bottom

    /// The edge the dropped pane is placed on, or `nil` for `.center`.
    public var edge: RiftEdge? {
        switch self {
        case .center: nil
        case .left: .left
        case .right: .right
        case .top: .top
        case .bottom: .bottom
        }
    }

    public init(edge: RiftEdge) {
        switch edge {
        case .left: self = .left
        case .right: self = .right
        case .top: self = .top
        case .bottom: self = .bottom
        }
    }
}

/// Identifies a node of a layout tree.
public enum RiftNodeID<PaneID: Hashable & Sendable>: Hashable, Sendable {
    case pane(PaneID)
    case split(UUID)
}
