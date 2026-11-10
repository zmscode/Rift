import Foundation

/// An immutable binary tree of panes. Leaves are pane identifiers; inner nodes are splits.
public indirect enum RiftLayout<PaneID: Hashable & Sendable>: Hashable, Sendable {
	case pane(PaneID)
	case split(RiftSplit<PaneID>)
}

/// A split divides its area between two children along an axis.
public struct RiftSplit<PaneID: Hashable & Sendable>: Hashable, Sendable, Identifiable {
	public var id: UUID
	public var axis: RiftAxis
	/// Fraction (0...1) of the available length (total minus divider) given to `first`.
	public var position: Double
	public var first: RiftLayout<PaneID>
	public var second: RiftLayout<PaneID>

	public init(
		id: UUID = UUID(),
		axis: RiftAxis,
		position: Double = 0.5,
		first: RiftLayout<PaneID>,
		second: RiftLayout<PaneID>
	) {
		self.id = id
		self.axis = axis
		self.position = position
		self.first = first
		self.second = second
	}
}

/// One step on the path from the root to a node.
public struct RiftPathStep<PaneID: Hashable & Sendable>: Sendable {
	public var split: RiftSplit<PaneID>
	/// Whether the path continues into `split.first`.
	public var inFirst: Bool
}

/// The result of detaching a node from a layout.
public struct RiftRemoval<PaneID: Hashable & Sendable>: Sendable {
	/// The layout left behind, or `nil` when the whole layout was removed.
	public var remaining: RiftLayout<PaneID>?
	/// The detached subtree.
	public var removed: RiftLayout<PaneID>
	/// The split that collapsed because one of its children left.
	public var collapsedSplitID: UUID?
	/// Where focus should go: the pane before the removed panes in layout order, else the one after.
	public var preferredFocus: PaneID?
}

// MARK: - Queries

extension RiftLayout {
	public var nodeID: RiftNodeID<PaneID> {
		switch self {
		case .pane(let id): .pane(id)
		case .split(let split): .split(split.id)
		}
	}

	/// Pane identifiers in reading order (left-to-right, top-to-bottom within each split).
	public var paneIDs: [PaneID] {
		var result: [PaneID] = []
		collectPanes(into: &result)
		return result
	}

	private func collectPanes(into result: inout [PaneID]) {
		switch self {
		case .pane(let id):
			result.append(id)
		case .split(let split):
			split.first.collectPanes(into: &result)
			split.second.collectPanes(into: &result)
		}
	}

	public var splitIDs: [UUID] {
		switch self {
		case .pane: []
		case .split(let split): [split.id] + split.first.splitIDs + split.second.splitIDs
		}
	}

	public var paneCount: Int {
		switch self {
		case .pane: 1
		case .split(let split): split.first.paneCount + split.second.paneCount
		}
	}

	/// The leading-most (left/top) pane.
	public var firstPaneID: PaneID {
		switch self {
		case .pane(let id): id
		case .split(let split): split.first.firstPaneID
		}
	}

	/// The trailing-most (right/bottom) pane.
	public var lastPaneID: PaneID {
		switch self {
		case .pane(let id): id
		case .split(let split): split.second.lastPaneID
		}
	}

	public func contains(_ pane: PaneID) -> Bool {
		switch self {
		case .pane(let id): id == pane
		case .split(let split): split.first.contains(pane) || split.second.contains(pane)
		}
	}

	public func contains(node: RiftNodeID<PaneID>) -> Bool { subtree(for: node) != nil }

	public func subtree(for node: RiftNodeID<PaneID>) -> RiftLayout? {
		if nodeID == node { return self }
		guard case .split(let split) = self else { return nil }
		return split.first.subtree(for: node) ?? split.second.subtree(for: node)
	}

	public func split(withID id: UUID) -> RiftSplit<PaneID>? {
		guard case .split(let split)? = subtree(for: .split(id)) else { return nil }
		return split
	}

	/// The splits from the root down to `pane`, or `nil` if the pane is absent.
	public func path(to pane: PaneID) -> [RiftPathStep<PaneID>]? {
		switch self {
		case .pane(let id):
			return id == pane ? [] : nil
		case .split(let split):
			if let rest = split.first.path(to: pane) {
				return [RiftPathStep(split: split, inFirst: true)] + rest
			}
			if let rest = split.second.path(to: pane) {
				return [RiftPathStep(split: split, inFirst: false)] + rest
			}
			return nil
		}
	}
}

// MARK: - Structural edits

extension RiftLayout {
	/// Replaces the node identified by `node` with `transform(node)`. Returns `nil` if absent.
	public func replacing(
		_ node: RiftNodeID<PaneID>,
		with transform: (RiftLayout) -> RiftLayout
	) -> RiftLayout? {
		if nodeID == node { return transform(self) }
		guard case .split(var split) = self else { return nil }
		if let first = split.first.replacing(node, with: transform) {
			split.first = first
			return .split(split)
		}
		if let second = split.second.replacing(node, with: transform) {
			split.second = second
			return .split(split)
		}
		return nil
	}

	/// Wraps the node `anchor` (a pane *or* a split) in a new split that places `subtree` on `edge`.
	///
	/// Anchoring on a split divides the full width or height of that subtree.
	public func inserting(
		_ subtree: RiftLayout,
		at anchor: RiftNodeID<PaneID>,
		edge: RiftEdge,
		splitID: UUID = UUID(),
		position: Double = 0.5
	) -> RiftLayout? {
		guard Set(subtree.paneIDs).isDisjoint(with: paneIDs) else { return nil }
		let clamped = position.isFinite ? min(max(position, 0), 1) : 0.5
		return replacing(anchor) { existing in
			.split(
				RiftSplit(
					id: splitID,
					axis: edge.axis,
					position: clamped,
					first: edge.isLeading ? subtree : existing,
					second: edge.isLeading ? existing : subtree
				))
		}
	}

	/// Splits `pane`, placing `newPane` on `edge` of it.
	public func splitting(
		_ pane: PaneID,
		with newPane: PaneID,
		edge: RiftEdge,
		splitID: UUID = UUID(),
		position: Double = 0.5
	) -> RiftLayout? {
		inserting(.pane(newPane), at: .pane(pane), edge: edge, splitID: splitID, position: position)
	}

	/// Places `subtree` along the full `edge` of the whole layout.
	public func wrapping(
		_ subtree: RiftLayout,
		edge: RiftEdge,
		splitID: UUID = UUID(),
		position: Double = 0.5
	) -> RiftLayout? {
		inserting(subtree, at: nodeID, edge: edge, splitID: splitID, position: position)
	}

	/// Detaches `node`, collapsing its parent split.
	///
	/// `preferredFocus` is the pane just before the removed panes in layout order, or, if there is
	/// none, the pane just after them.
	public func removing(_ node: RiftNodeID<PaneID>) -> RiftRemoval<PaneID>? {
		guard var removal = removingNode(node) else { return nil }
		let removed = Set(removal.removed.paneIDs)
		let order = paneIDs
		if let first = order.firstIndex(where: removed.contains),
			let last = order.lastIndex(where: removed.contains)
		{
			removal.preferredFocus =
				first > order.startIndex
				? order[first - 1]
				: (last + 1 < order.endIndex ? order[last + 1] : nil)
		}
		return removal
	}

	private func removingNode(_ node: RiftNodeID<PaneID>) -> RiftRemoval<PaneID>? {
		if nodeID == node {
			return RiftRemoval(
				remaining: nil, removed: self, collapsedSplitID: nil, preferredFocus: nil)
		}
		guard case .split(var split) = self else { return nil }
		if split.first.nodeID == node {
			return RiftRemoval(
				remaining: split.second,
				removed: split.first,
				collapsedSplitID: split.id,
				preferredFocus: split.second.firstPaneID
			)
		}
		if split.second.nodeID == node {
			return RiftRemoval(
				remaining: split.first,
				removed: split.second,
				collapsedSplitID: split.id,
				preferredFocus: split.first.lastPaneID
			)
		}
		if var removal = split.first.removingNode(node), let rest = removal.remaining {
			split.first = rest
			removal.remaining = .split(split)
			return removal
		}
		if var removal = split.second.removingNode(node), let rest = removal.remaining {
			split.second = rest
			removal.remaining = .split(split)
			return removal
		}
		return nil
	}

	/// Exchanges the positions of two panes.
	public func swapping(_ a: PaneID, _ b: PaneID) -> RiftLayout? {
		guard a != b, contains(a), contains(b) else { return nil }
		return mapPanes { $0 == a ? b : ($0 == b ? a : $0) }
	}

	/// Moves `source` next to `target`. `.center` swaps the two panes.
	public func moving(
		_ source: PaneID,
		to target: PaneID,
		zone: RiftDropZone,
		splitID: UUID = UUID(),
		position: Double = 0.5
	) -> RiftLayout? {
		guard source != target, contains(source), contains(target) else { return nil }
		guard let edge = zone.edge else { return swapping(source, target) }
		guard let remaining = removing(.pane(source))?.remaining else { return nil }
		return remaining.splitting(
			target, with: source, edge: edge, splitID: splitID, position: position)
	}

	/// Moves a pane between two layouts (for example another tab or window).
	///
	/// When `destination` is `nil` the pane becomes the destination's only pane.
	/// When `target` is `nil` the pane is placed along `edge` of the whole destination.
	public static func transferring(
		_ pane: PaneID,
		from source: RiftLayout,
		to destination: RiftLayout?,
		target: PaneID?,
		edge: RiftEdge,
		splitID: UUID = UUID(),
		position: Double = 0.5
	) -> (source: RiftLayout?, destination: RiftLayout)? {
		guard let removal = source.removing(.pane(pane)) else { return nil }
		guard let destination else { return (removal.remaining, .pane(pane)) }
		guard !destination.contains(pane) else { return nil }
		let result: RiftLayout?
		if let target {
			result = destination.splitting(
				target, with: pane, edge: edge, splitID: splitID, position: position)
		} else {
			result = destination.wrapping(
				.pane(pane), edge: edge, splitID: splitID, position: position)
		}
		guard let result else { return nil }
		return (removal.remaining, result)
	}

	public func mapPanes<Other: Hashable & Sendable>(_ transform: (PaneID) -> Other) -> RiftLayout<
		Other
	> {
		switch self {
		case .pane(let id):
			return .pane(transform(id))
		case .split(let split):
			return .split(
				RiftSplit(
					id: split.id,
					axis: split.axis,
					position: split.position,
					first: split.first.mapPanes(transform),
					second: split.second.mapPanes(transform)
				))
		}
	}
}

// MARK: - Divider positions

extension RiftLayout {
	public func position(ofSplit id: UUID) -> Double? { split(withID: id)?.position }

	/// Sets a split's fraction, clamped to 0...1. Returns `nil` for an unknown split or non-finite value.
	public func settingPosition(_ position: Double, ofSplit id: UUID) -> RiftLayout? {
		guard position.isFinite else { return nil }
		let clamped = min(max(position, 0), 1)
		return replacing(.split(id)) { node in
			guard case .split(var split) = node else { return node }
			split.position = clamped
			return .split(split)
		}
	}

	/// Applies a batch of divider updates, ignoring unknown splits.
	public func applying(_ updates: [RiftDividerUpdate]) -> RiftLayout {
		updates.reduce(self) { layout, update in
			layout.settingPosition(update.position, ofSplit: update.splitID) ?? layout
		}
	}
}

// MARK: - Validation

public enum RiftLayoutIssue<PaneID: Hashable & Sendable>: Hashable, Sendable {
	case duplicatePane(PaneID)
	case duplicateSplit(UUID)
	case invalidPosition(UUID)
}

public struct RiftLayoutValidationError<PaneID: Hashable & Sendable>: Error, Sendable {
	public var issues: [RiftLayoutIssue<PaneID>]
}

extension RiftLayout {
	public var validationIssues: [RiftLayoutIssue<PaneID>] {
		var issues: [RiftLayoutIssue<PaneID>] = []
		var panes = Set<PaneID>()
		var splits = Set<UUID>()
		func visit(_ node: RiftLayout) {
			switch node {
			case .pane(let id):
				if !panes.insert(id).inserted { issues.append(.duplicatePane(id)) }
			case .split(let split):
				if !splits.insert(split.id).inserted { issues.append(.duplicateSplit(split.id)) }
				if !split.position.isFinite || split.position < 0 || split.position > 1 {
					issues.append(.invalidPosition(split.id))
				}
				visit(split.first)
				visit(split.second)
			}
		}
		visit(self)
		return issues
	}

	public func validate() throws {
		let issues = validationIssues
		if !issues.isEmpty { throw RiftLayoutValidationError(issues: issues) }
	}
}

// MARK: - Codable

extension RiftLayout: Codable where PaneID: Codable {
	private enum CodingKeys: String, CodingKey {
		case type, pane, id, axis, position, first, second
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		switch try container.decode(String.self, forKey: .type) {
		case "pane":
			self = .pane(try container.decode(PaneID.self, forKey: .pane))
		case "split":
			self = .split(
				RiftSplit(
					id: try container.decode(UUID.self, forKey: .id),
					axis: try container.decode(RiftAxis.self, forKey: .axis),
					position: try container.decode(Double.self, forKey: .position),
					first: try container.decode(RiftLayout.self, forKey: .first),
					second: try container.decode(RiftLayout.self, forKey: .second)
				))
		case let other:
			throw DecodingError.dataCorruptedError(
				forKey: .type, in: container, debugDescription: "Unknown Rift node type \(other)")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case .pane(let id):
			try container.encode("pane", forKey: .type)
			try container.encode(id, forKey: .pane)
		case .split(let split):
			try container.encode("split", forKey: .type)
			try container.encode(split.id, forKey: .id)
			try container.encode(split.axis, forKey: .axis)
			try container.encode(split.position, forKey: .position)
			try container.encode(split.first, forKey: .first)
			try container.encode(split.second, forKey: .second)
		}
	}
}
