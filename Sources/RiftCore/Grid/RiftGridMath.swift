import CoreGraphics
import Foundation

/// How many columns a grid has.
public enum RiftGridColumns: Sendable, Hashable {
	/// As many cells of the item size as fit across the width (at least one).
	case fitting
	/// Exactly this many (at least one), whatever the width.
	case fixed(Int)
}

/// The numbers a grid is laid out with.
public struct RiftGridMetrics: Sendable, Hashable {
	/// The size of a cell. With `stretchesCells`, the least width of one.
	public var itemSize: CGSize
	/// The space between columns (`width`) and between rows (`height`).
	public var spacing: CGSize
	/// The space around the whole grid.
	public var inset: CGSize
	public var columns: RiftGridColumns
	/// Cells widen to share the space left over across a row, so the grid always fills its width.
	/// Otherwise they keep `itemSize` and the grid is aligned to the leading edge.
	public var stretchesCells: Bool
	/// At most this many rows; items past the last row are not laid out (`nil`: no limit).
	public var maximumRows: Int?

	public init(
		itemSize: CGSize = CGSize(width: 96, height: 96),
		spacing: CGSize = CGSize(width: 8, height: 8),
		inset: CGSize = CGSize(width: 12, height: 12),
		columns: RiftGridColumns = .fitting, stretchesCells: Bool = true, maximumRows: Int? = nil
	) {
		self.itemSize = itemSize
		self.spacing = spacing
		self.inset = inset
		self.columns = columns
		self.stretchesCells = stretchesCells
		self.maximumRows = maximumRows
	}
}

/// Where something dragged over a grid would land.
public enum RiftGridDropTarget: Sendable, Hashable {
	/// Between items: it becomes the item at this index (0…count).
	case between(Int)
	/// Onto the item at this index (into a folder, say).
	case onto(Int)
}

/// A grid of `count` equal cells laid out in rows, left to right, top to bottom, in a space
/// `width` wide. The origin is the top-left and y grows downward.
public struct RiftGridLayout: Sendable, Hashable {
	public let count: Int
	public let columns: Int
	public let rows: Int
	public let cellSize: CGSize
	public let metrics: RiftGridMetrics
	public let width: CGFloat

	public init(count: Int, width: CGFloat, metrics: RiftGridMetrics = RiftGridMetrics()) {
		self.metrics = metrics
		self.width = width
		let available = max(0, width - 2 * metrics.inset.width)
		let itemWidth = max(1, metrics.itemSize.width)
		let columns: Int
		switch metrics.columns {
		case .fixed(let n):
			columns = max(1, n)
		case .fitting:
			columns = max(
				1,
				RiftGridLayout.whole(
					((available + metrics.spacing.width) / (itemWidth + metrics.spacing.width))
						.rounded(.down)))
		}
		self.columns = columns
		let gaps = CGFloat(columns - 1) * metrics.spacing.width
		let stretched = max(0, (available - gaps) / CGFloat(columns))
		// A fixed column count always shares the width; fitted columns only widen.
		let cellWidth: CGFloat
		switch metrics.columns {
		case .fixed: cellWidth = metrics.stretchesCells ? stretched : min(itemWidth, stretched)
		case .fitting:
			cellWidth =
				metrics.stretchesCells
				? max(stretched, min(itemWidth, available)) : min(itemWidth, available)
		}
		cellSize = CGSize(width: cellWidth.rounded(.down), height: max(0, metrics.itemSize.height))
		let allRows = count <= 0 ? 0 : (count + columns - 1) / columns
		rows = metrics.maximumRows.map { min(allRows, max(0, $0)) } ?? allRows
		self.count = min(max(count, 0), rows * columns)
	}

	/// A length ratio as a whole number, safe for values that are not finite or are far out of
	/// range (a view's visible rectangle before it is in a window, say).
	static func whole(_ value: CGFloat) -> Int {
		guard value.isFinite else { return 0 }
		return Int(min(max(value, -1e9), 1e9))
	}

	/// The height of all the rows with the insets above and below.
	public var contentHeight: CGFloat {
		guard rows > 0 else { return 2 * metrics.inset.height }
		return 2 * metrics.inset.height + CGFloat(rows) * cellSize.height
			+ CGFloat(rows - 1) * metrics.spacing.height
	}

	private var columnStride: CGFloat { cellSize.width + metrics.spacing.width }
	private var rowStride: CGFloat { cellSize.height + metrics.spacing.height }

	/// The frame of the cell in slot `index` (slots past `count` continue the pattern, which is
	/// where an item dropped at the end goes).
	public func frame(at index: Int) -> CGRect {
		let column = index % columns
		let row = index / columns
		return CGRect(
			x: metrics.inset.width + CGFloat(column) * columnStride,
			y: metrics.inset.height + CGFloat(row) * rowStride, width: cellSize.width,
			height: cellSize.height)
	}

	public func row(of index: Int) -> Int { index / columns }
	public func column(of index: Int) -> Int { index % columns }

	/// The item whose cell contains `point`, if any (the spacing between cells belongs to none).
	public func index(at point: CGPoint) -> Int? {
		guard count > 0, columnStride > 0, rowStride > 0 else { return nil }
		let x = point.x - metrics.inset.width
		let y = point.y - metrics.inset.height
		guard x >= 0, y >= 0 else { return nil }
		let column = RiftGridLayout.whole(x / columnStride)
		let row = RiftGridLayout.whole(y / rowStride)
		guard column < columns, row < rows else { return nil }
		let index = row * columns + column
		guard index < count, frame(at: index).contains(point) else { return nil }
		return index
	}

	/// The slot nearest `point` (0…`slots − 1`): the row and column the point falls in, counting
	/// the spacing after a cell as part of it, and clamped to the grid.
	public func nearestSlot(to point: CGPoint, slots: Int) -> Int {
		guard slots > 0 else { return 0 }
		let lastRow = (slots - 1) / columns
		let column = min(
			max(RiftGridLayout.whole(((point.x - metrics.inset.width) / max(columnStride, 1)).rounded(.down)), 0),
			columns - 1)
		let row = min(
			max(RiftGridLayout.whole(((point.y - metrics.inset.height) / max(rowStride, 1)).rounded(.down)), 0),
			lastRow)
		return min(row * columns + column, slots - 1)
	}

	/// Where a drag at `point` would land. Over the middle half of a cell that `acceptsOnto`, it
	/// lands onto that item. Otherwise it lands between items: before the nearest cell when the
	/// point is in its leading half, after it in its trailing half.
	public func dropTarget(at point: CGPoint, acceptsOnto: (Int) -> Bool = { _ in false })
		-> RiftGridDropTarget
	{
		guard count > 0 else { return .between(0) }
		if let over = index(at: point), acceptsOnto(over) {
			let frame = frame(at: over)
			if abs(point.x - frame.midX) <= frame.width / 4 { return .onto(over) }
		}
		let slot = nearestSlot(to: point, slots: count)
		let after = point.x > frame(at: slot).midX
		return .between(min(slot + (after ? 1 : 0), count))
	}

	/// The items whose cells touch `rect` (a selection rectangle), in order.
	public func indices(intersecting rect: CGRect) -> [Int] {
		guard count > 0, rect.width >= 0, rect.height >= 0, rowStride > 0 else { return [] }
		let firstRow = max(0, RiftGridLayout.whole(((rect.minY - metrics.inset.height) / rowStride).rounded(.down)))
		let lastRow = min(
			rows - 1, RiftGridLayout.whole(((rect.maxY - metrics.inset.height) / rowStride).rounded(.down)))
		guard firstRow <= lastRow else { return [] }
		var result: [Int] = []
		for row in firstRow...lastRow {
			for column in 0..<columns {
				let index = row * columns + column
				guard index < count else { break }
				if frame(at: index).intersects(rect) { result.append(index) }
			}
		}
		return result
	}

	/// The rows that show in a strip from `minY` to `maxY`, with `overscan` extra rows either side.
	public func visibleIndices(minY: CGFloat, maxY: CGFloat, overscan: Int = 1) -> Range<Int> {
		guard count > 0, rowStride > 0, minY.isFinite, maxY.isFinite, maxY >= minY else {
			return 0..<0
		}
		// Kept to the rows there are before converting, so a far-off strip can't overflow.
		let limit = CGFloat(rows + overscan + 1)
		func row(_ y: CGFloat) -> Int {
			RiftGridLayout.whole(min(max(((y - metrics.inset.height) / rowStride).rounded(.down), -limit), limit))
		}
		let first = row(minY) - overscan
		let last = row(maxY) + overscan
		let lower = min(max(first, 0) * columns, count)
		let upper = min(max(last + 1, 0) * columns, count)
		return lower..<max(lower, upper)
	}

	/// The item an arrow key moves to from `index`: one column left or right (staying in the row),
	/// or one row up or down (the last row's missing cells send "down" to the last item).
	public func index(from index: Int, moving direction: RiftDirection) -> Int? {
		guard count > 0, index >= 0, index < count else { return count > 0 ? 0 : nil }
		switch direction {
		case .left: return column(of: index) > 0 ? index - 1 : nil
		case .right:
			return column(of: index) < columns - 1 && index + 1 < count ? index + 1 : nil
		case .up: return index - columns >= 0 ? index - columns : nil
		case .down:
			if index + columns < count { return index + columns }
			return row(of: index) < rows - 1 ? count - 1 : nil
		}
	}
}

/// Pure helpers for reordering and selecting in a grid.
public enum RiftGridMath {
	/// `items` with `moved` taken out and put back together, in their original order, so that the
	/// first of them is at `index` of what is left (0…remaining count).
	public static func moving<ID: Hashable>(_ moved: Set<ID>, in items: [ID], to index: Int) -> [ID]
	{
		let taken = items.filter(moved.contains)
		var rest = items.filter { !moved.contains($0) }
		rest.insert(contentsOf: taken, at: min(max(index, 0), rest.count))
		return rest
	}

	/// The index among the items that stay (those not in `moved`) for a drop `between` the
	/// original items at `index`.
	public static func insertionIndex<ID: Hashable>(
		forDropAt index: Int, in items: [ID], moving moved: Set<ID>
	) -> Int {
		items.prefix(min(max(index, 0), items.count)).filter { !moved.contains($0) }.count
	}

	/// The items from `anchor` to `end` inclusive, in either direction (a Shift-click).
	public static func range<ID: Hashable>(from anchor: ID, to end: ID, in items: [ID]) -> [ID] {
		guard let a = items.firstIndex(of: anchor), let b = items.firstIndex(of: end) else {
			return items.contains(end) ? [end] : []
		}
		return Array(items[min(a, b)...max(a, b)])
	}
}
