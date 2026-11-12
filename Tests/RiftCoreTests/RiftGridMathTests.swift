import CoreGraphics
import Foundation
import Testing

@testable import RiftCore

@Suite struct GridLayoutTests {
	let metrics = RiftGridMetrics(
		itemSize: CGSize(width: 100, height: 80), spacing: CGSize(width: 10, height: 10),
		inset: CGSize(width: 20, height: 20))

	@Test func fittingColumnsFollowTheWidth() {
		// 20 + 100 + 10 + 100 + 10 + 100 + 20 = 360 is the least width for three columns.
		#expect(RiftGridLayout(count: 7, width: 360, metrics: metrics).columns == 3)
		#expect(RiftGridLayout(count: 7, width: 359, metrics: metrics).columns == 2)
		#expect(RiftGridLayout(count: 7, width: 50, metrics: metrics).columns == 1)
		let layout = RiftGridLayout(count: 7, width: 400, metrics: metrics)
		#expect(layout.columns == 3 && layout.rows == 3)
		// The 40pt left over is shared: (400 − 40 − 20) / 3 = 113.
		#expect(layout.cellSize == CGSize(width: 113, height: 80))
		#expect(layout.frame(at: 4) == CGRect(x: 143, y: 110, width: 113, height: 80))
		#expect(layout.contentHeight == CGFloat(300))  // 40 + 3 × 80 + 2 × 10
	}

	@Test func fixedColumnsShareTheWidth() {
		var fixed = metrics
		fixed.columns = .fixed(4)
		let layout = RiftGridLayout(count: 6, width: 300, metrics: fixed)
		#expect(layout.columns == 4 && layout.rows == 2)
		#expect(layout.cellSize.width == 57)  // (300 − 40 − 30) / 4, rounded down
		fixed.stretchesCells = false
		#expect(RiftGridLayout(count: 6, width: 900, metrics: fixed).cellSize.width == 100)
		fixed.maximumRows = 1
		let capped = RiftGridLayout(count: 6, width: 900, metrics: fixed)
		#expect(capped.rows == 1 && capped.count == 4)
	}

	@Test func hitTestingLeavesOutTheSpacing() {
		let layout = RiftGridLayout(count: 5, width: 360, metrics: metrics)
		#expect(layout.index(at: CGPoint(x: 30, y: 30)) == 0)
		#expect(layout.index(at: CGPoint(x: 125, y: 30)) == nil)  // between columns
		#expect(layout.index(at: CGPoint(x: 140, y: 120)) == 4)
		#expect(layout.index(at: CGPoint(x: 250, y: 120)) == nil)  // an empty slot
		#expect(layout.index(at: CGPoint(x: 5, y: 5)) == nil)
	}

	@Test func dropsLandBetweenOrOnto() {
		let layout = RiftGridLayout(count: 5, width: 360, metrics: metrics)
		// Leading and trailing halves of the first cell (20…120).
		#expect(layout.dropTarget(at: CGPoint(x: 30, y: 30)) == .between(0))
		#expect(layout.dropTarget(at: CGPoint(x: 110, y: 30)) == .between(1))
		// The middle half of a cell that takes drops.
		#expect(layout.dropTarget(at: CGPoint(x: 70, y: 30)) { $0 == 0 } == .onto(0))
		#expect(layout.dropTarget(at: CGPoint(x: 30, y: 30)) { $0 == 0 } == .between(0))
		// Past the last item.
		#expect(layout.dropTarget(at: CGPoint(x: 340, y: 500)) == .between(5))
		#expect(
			RiftGridLayout(count: 0, width: 360, metrics: metrics)
				.dropTarget(at: .zero) == .between(0))
	}

	@Test func selectionRectanglesAndVisibleRows() {
		let layout = RiftGridLayout(count: 8, width: 360, metrics: metrics)
		#expect(
			layout.indices(intersecting: CGRect(x: 100, y: 50, width: 60, height: 80))
				== [0, 1, 3, 4])
		#expect(layout.indices(intersecting: CGRect(x: 0, y: 0, width: 5, height: 5)).isEmpty)
		// Rows are 90pt apart from y = 20.
		#expect(layout.visibleIndices(minY: 0, maxY: 100, overscan: 0) == 0..<3)
		#expect(layout.visibleIndices(minY: 120, maxY: 300, overscan: 0) == 3..<8)
		#expect(layout.visibleIndices(minY: 120, maxY: 130, overscan: 1) == 0..<8)
	}

	@Test func arrowKeysMoveByCell() {
		let layout = RiftGridLayout(count: 8, width: 360, metrics: metrics)  // 3 + 3 + 2
		#expect(layout.index(from: 1, moving: .right) == 2)
		#expect(layout.index(from: 2, moving: .right) == nil)
		#expect(layout.index(from: 3, moving: .left) == nil)
		#expect(layout.index(from: 4, moving: .up) == 1)
		#expect(layout.index(from: 4, moving: .down) == 7)
		// No cell below the third column of the second row: go to the last item.
		#expect(layout.index(from: 5, moving: .down) == 7)
		#expect(layout.index(from: 7, moving: .down) == nil)
	}

	@Test func tinyAndEmptyGridsStaySane() {
		let empty = RiftGridLayout(count: 0, width: 0, metrics: metrics)
		#expect(empty.rows == 0 && empty.columns == 1 && empty.contentHeight == 40)
		let narrow = RiftGridLayout(count: 3, width: 30, metrics: metrics)
		#expect(narrow.columns == 1 && narrow.cellSize.width == 0)
		#expect(narrow.frame(at: 2).width >= 0)
		// A view that isn't in a window yet reports an infinite visible rectangle.
		let layout = RiftGridLayout(count: 8, width: 360, metrics: metrics)
		#expect(layout.visibleIndices(minY: .infinity, maxY: .infinity).isEmpty)
		#expect(layout.visibleIndices(minY: -1e300, maxY: 1e300) == 0..<8)
		#expect(layout.index(at: CGPoint(x: CGFloat.infinity, y: 30)) == nil)
		#expect(layout.nearestSlot(to: CGPoint(x: -1e300, y: 1e300), slots: 8) == 6)
		#expect(RiftGridLayout(count: 3, width: .infinity, metrics: metrics).columns >= 1)
	}
}

@Suite struct GridMathTests {
	@Test func movingKeepsTheMovedItemsTogether() {
		let items = ["a", "b", "c", "d", "e"]
		#expect(RiftGridMath.moving(["b", "d"], in: items, to: 0) == ["b", "d", "a", "c", "e"])
		#expect(RiftGridMath.moving(["b", "d"], in: items, to: 3) == ["a", "c", "e", "b", "d"])
		#expect(RiftGridMath.moving(["a"], in: items, to: 99) == ["b", "c", "d", "e", "a"])
		// A drop before "e" (index 4) while moving b and d: two of the first four stay.
		#expect(RiftGridMath.insertionIndex(forDropAt: 4, in: items, moving: ["b", "d"]) == 2)
	}

	@Test func rangesRunEitherWay() {
		let items = ["a", "b", "c", "d"]
		#expect(RiftGridMath.range(from: "b", to: "d", in: items) == ["b", "c", "d"])
		#expect(RiftGridMath.range(from: "d", to: "b", in: items) == ["b", "c", "d"])
		#expect(RiftGridMath.range(from: "z", to: "c", in: items) == ["c"])
	}
}
