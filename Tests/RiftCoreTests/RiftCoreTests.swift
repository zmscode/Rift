import CoreGraphics
import Foundation
import Testing

@testable import RiftCore

typealias Layout = RiftLayout<String>

/// a | (b / c)
private func threePanes() -> Layout {
	Layout.pane("a")
		.splitting("a", with: "b", edge: .right)!
		.splitting("b", with: "c", edge: .bottom)!
}

private let noMinimums = RiftMetrics(dividerThickness: 0, minimumPaneSize: .zero, displayScale: 0)

@Suite struct TreeTests {
	@Test func splittingPlacesNewPaneOnEdge() {
		#expect(threePanes().paneIDs == ["a", "b", "c"])
		let left = Layout.pane("a").splitting("a", with: "z", edge: .left)!
		#expect(left.paneIDs == ["z", "a"])
		guard case .split(let split) = left else {
			Issue.record("expected split")
			return
		}
		#expect(split.axis == .horizontal)
	}

	@Test func splittingRejectsDuplicatesAndUnknownTargets() {
		#expect(threePanes().splitting("a", with: "b", edge: .right) == nil)
		#expect(threePanes().splitting("nope", with: "d", edge: .right) == nil)
	}

	@Test func wrappingSpansWholeLayout() {
		let base = threePanes()
		let wrapped = base.wrapping(.pane("d"), edge: .bottom)!
		guard case .split(let root) = wrapped else {
			Issue.record("expected split")
			return
		}
		#expect(root.axis == .vertical)
		#expect(root.second == .pane("d"))
		#expect(root.first == base)
	}

	@Test func removingCollapsesParentAndPicksNeighbour() {
		let layout = threePanes()
		let removal = layout.removing(.pane("b"))!
		#expect(removal.remaining?.paneIDs == ["a", "c"])
		#expect(removal.preferredFocus == "c")
		#expect(removal.collapsedSplitID != nil)

		let lastRemoval = Layout.pane("a").removing(.pane("a"))!
		#expect(lastRemoval.remaining == nil)
		#expect(layout.removing(.pane("missing")) == nil)
	}

	@Test func movingToEdgeAndCenter() {
		let layout = threePanes()
		let moved = layout.moving("c", to: "a", zone: .top)!
		#expect(moved.paneIDs == ["c", "a", "b"])
		let swapped = layout.moving("a", to: "c", zone: .center)!
		#expect(swapped.paneIDs == ["c", "b", "a"])
		#expect(layout.moving("a", to: "a", zone: .left) == nil)
	}

	@Test func transferringBetweenLayouts() {
		let result = Layout.transferring(
			"b", from: threePanes(), to: .pane("x"), target: "x", edge: .left)!
		#expect(result.source?.paneIDs == ["a", "c"])
		#expect(result.destination.paneIDs == ["b", "x"])

		let intoEmpty = Layout.transferring(
			"a", from: .pane("a"), to: nil, target: nil, edge: .right)!
		#expect(intoEmpty.source == nil)
		#expect(intoEmpty.destination == .pane("a"))
	}

	@Test func positionsAreClamped() {
		let layout = threePanes()
		let id = layout.splitIDs[0]
		#expect(layout.settingPosition(1.7, ofSplit: id)?.position(ofSplit: id) == 1)
		#expect(layout.settingPosition(.nan, ofSplit: id) == nil)
	}

	@Test func validationFindsDuplicates() {
		let id = UUID()
		let bad = Layout.split(
			RiftSplit(id: id, axis: .horizontal, position: 2, first: .pane("a"), second: .pane("a"))
		)
		let issues = bad.validationIssues
		#expect(issues.contains(.duplicatePane("a")))
		#expect(issues.contains(.invalidPosition(id)))
		#expect(throws: RiftLayoutValidationError<String>.self) { try bad.validate() }
		#expect(throws: Never.self) { try threePanes().validate() }
	}

	@Test func codableRoundTrip() throws {
		let layout = threePanes()
		let data = try JSONEncoder().encode(layout)
		#expect(try JSONDecoder().decode(Layout.self, from: data) == layout)
	}
}

@Suite struct GeometryTests {
	@Test func framesTileTheBoundsWithDividers() {
		let metrics = RiftMetrics(dividerThickness: 1, minimumPaneSize: .zero, displayScale: 1)
		let geometry = threePanes().geometry(
			in: CGRect(x: 0, y: 0, width: 201, height: 101), metrics: metrics)
		#expect(geometry.paneFrames["a"] == CGRect(x: 0, y: 0, width: 100, height: 101))
		#expect(geometry.paneFrames["b"] == CGRect(x: 101, y: 0, width: 100, height: 50))
		#expect(geometry.paneFrames["c"] == CGRect(x: 101, y: 51, width: 100, height: 50))
		#expect(geometry.dividers.count == 2)
		#expect(geometry.pane(at: CGPoint(x: 150, y: 80)) == "c")
	}

	@Test func minimumSizesClampDividers() {
		let metrics = RiftMetrics(
			dividerThickness: 0, minimumPaneSize: CGSize(width: 50, height: 50), displayScale: 0)
		let layout = Layout.pane("a").splitting("a", with: "b", edge: .right, position: 0.05)!
		let geometry = layout.geometry(
			in: CGRect(x: 0, y: 0, width: 200, height: 100), metrics: metrics)
		#expect(geometry.paneFrames["a"]?.width == 50)
	}

	@Test func tooSmallSharesSpaceProportionally() {
		let range = RiftDividerMath.lengthRange(available: 60, minLeading: 40, minTrailing: 80)
		#expect(range.lowerBound == 20)
		#expect(range.upperBound == 20)
	}
}

@Suite struct DividerDragTests {
	private let snap = RiftSnapConfiguration()

	@Test func snapsWithinRadiusAndHoldsLonger() {
		let near = RiftDividerMath.dragPosition(
			leadingOffset: 108, available: 200, minLeading: 0, minTrailing: 0, wasCentered: false,
			snap: snap)
		#expect(near.position == 0.5 && near.isSnappedToCenter)

		let outside = RiftDividerMath.dragPosition(
			leadingOffset: 113, available: 200, minLeading: 0, minTrailing: 0, wasCentered: false,
			snap: snap)
		#expect(!outside.isSnappedToCenter)
		#expect(abs(outside.position - 0.565) < 1e-9)

		let held = RiftDividerMath.dragPosition(
			leadingOffset: 113, available: 200, minLeading: 0, minTrailing: 0, wasCentered: true,
			snap: snap)
		#expect(held.isSnappedToCenter)
	}

	@Test func noSnapWhenCenterIsUnreachable() {
		let result = RiftDividerMath.dragPosition(
			leadingOffset: 100, available: 200, minLeading: 120, minTrailing: 0, wasCentered: false,
			snap: snap)
		#expect(!result.isSnappedToCenter)
		#expect(result.position == 0.6)
	}

	@Test func dragReportsNewSnapOnce() {
		let layout = Layout.pane("a").splitting("a", with: "b", edge: .right, position: 0.25)!
		let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
		let geometry = layout.geometry(in: bounds, metrics: noMinimums)
		let start = CGPoint(x: 50, y: 50)
		let hit = geometry.dividerHit(at: start, hitThickness: 8)!
		var drag = RiftDividerDrag(hit: hit, pointer: start)

		let first = drag.update(
			pointer: CGPoint(x: 95, y: 50), geometry: geometry, metrics: noMinimums, snap: snap)
		#expect(first.didSnap)
		#expect(first.updates.first?.position == 0.5)

		let second = drag.update(
			pointer: CGPoint(x: 97, y: 50), geometry: geometry, metrics: noMinimums, snap: snap)
		#expect(!second.didSnap)
		#expect(second.updates.first?.isSnappedToCenter == true)
	}

	@Test func intersectionGrabsBothAxes() {
		// (a | b) over c: the vertical split's divider meets the horizontal one.
		let layout = Layout.pane("a")
			.splitting("a", with: "b", edge: .right)!
			.wrapping(.pane("c"), edge: .bottom)!
		let geometry = layout.geometry(
			in: CGRect(x: 0, y: 0, width: 200, height: 200), metrics: noMinimums)
		let hit = geometry.dividerHit(at: CGPoint(x: 100, y: 99), hitThickness: 8)!
		#expect(hit.isIntersection)
		#expect(hit.dividers.count == 2)
	}

	@Test func movingDividerByPoints() {
		let layout = Layout.pane("a").splitting("a", with: "b", edge: .right)!
		let id = layout.splitIDs[0]
		let moved = layout.movingDivider(
			id, by: 20, in: CGRect(x: 0, y: 0, width: 200, height: 100), metrics: noMinimums)!
		#expect(moved.position(ofSplit: id) == 0.6)
	}
}

@Suite struct DropZoneTests {
	@Test func bandsPreferEightyPointsWithinAQuarterToAThird() {
		#expect(RiftDropZone.bandLength(for: 400) == 100)  // quarter is already ≥ 80
		#expect(RiftDropZone.bandLength(for: 300) == 80)  // quarter 75 < 80, third 100
		#expect(abs(RiftDropZone.bandLength(for: 180) - 60) < 1e-9)  // third caps it
	}

	@Test func classifyChecksSidesFirst() {
		let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
		#expect(RiftDropZone.classify(CGPoint(x: 150, y: 120), in: frame) == .left)  // corner → side
		#expect(RiftDropZone.classify(CGPoint(x: 450, y: 250), in: frame) == .right)
		#expect(RiftDropZone.classify(CGPoint(x: 300, y: 120), in: frame) == .top)
		#expect(RiftDropZone.classify(CGPoint(x: 300, y: 390), in: frame) == .bottom)
		#expect(RiftDropZone.classify(CGPoint(x: 300, y: 250), in: frame) == .center)
	}

	@Test func indicatorCoversTheLandingHalf() {
		let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
		#expect(
			RiftDropZone.left.indicatorRect(in: frame) == CGRect(x: 4, y: 4, width: 96, height: 92))
		#expect(
			RiftDropZone.right.indicatorRect(in: frame)
				== CGRect(x: 100, y: 4, width: 96, height: 92))
		#expect(
			RiftDropZone.bottom.indicatorRect(in: frame)
				== CGRect(x: 4, y: 50, width: 192, height: 46))
		#expect(
			RiftDropZone.center.indicatorRect(in: frame)
				== CGRect(x: 4, y: 4, width: 192, height: 92))
	}
}

@Suite struct ArrangementTests {
	@Test func balanceGivesEachColumnEqualWidth() {
		// a | (b / c) | d  — three columns.
		let layout = threePanes().splitting("b", with: "d", edge: .right)!
		let balanced = layout.balanced()
		let geometry = balanced.geometry(
			in: CGRect(x: 0, y: 0, width: 300, height: 100), metrics: noMinimums)
		#expect(geometry.paneFrames["a"]?.width == 100)
		#expect(geometry.paneFrames["d"]?.width == 100)
	}

	@Test func balanceKeepsPlacedDividers() {
		let layout = threePanes()
		let root = layout.splitIDs[0]
		let custom = layout.settingPosition(0.3, ofSplit: root)!
		#expect(custom.balanced(keeping: [root]).position(ofSplit: root) == 0.3)
	}

	@Test func resizingUsesTheBorderingSplit() {
		let layout = threePanes()
		let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
		#expect(layout.splitID(bordering: "a", on: .right) == layout.splitIDs[0])
		#expect(layout.splitID(bordering: "a", on: .left) == nil)
		let grown = layout.resizing("c", toward: .left, by: 20, in: bounds, metrics: noMinimums)!
		#expect(grown.position(ofSplit: layout.splitIDs[0]) == 0.4)
	}

	@Test func neighbourNavigation() {
		let layout = threePanes()
		let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
		#expect(layout.neighbor(of: "a", toward: .right, in: bounds, metrics: noMinimums) != nil)
		#expect(layout.neighbor(of: "b", toward: .down, in: bounds, metrics: noMinimums) == "c")
		#expect(layout.neighbor(of: "c", toward: .left, in: bounds, metrics: noMinimums) == "a")
		#expect(layout.neighbor(of: "a", toward: .left, in: bounds, metrics: noMinimums) == nil)
		#expect(
			layout.neighbor(of: "c", toward: .down, in: bounds, metrics: noMinimums, wraps: true)
				== "b")
	}
}
