import CoreGraphics
import Foundation
import Testing

@testable import RiftCore

@Suite struct FloatingGeometryTests {
	let area = CGRect(x: 0, y: 0, width: 1000, height: 800)

	@Test func newLayersAreCappedSizedAndCentred() {
		let a = RiftFloatingGeometry.newBounds(
			for: CGSize(width: 900, height: 700), in: area, existing: [])
		#expect(a.size == CGSize(width: 550, height: 480))  // 55% wide, 60% tall
		#expect(a.midX == 500 && a.midY == 400)
		let small = RiftFloatingGeometry.newBounds(
			for: CGSize(width: 100, height: 80), in: area, existing: [])
		#expect(small.size == CGSize(width: 240, height: 150))
		let cascaded = RiftFloatingGeometry.newBounds(
			for: CGSize(width: 900, height: 700), in: area, existing: [a])
		#expect(cascaded.origin == CGPoint(x: a.minX + 28, y: a.minY + 28))
	}

	@Test func movesStayInsideWithAGivePastTheEdges() {
		let start = CGRect(x: 100, y: 100, width: 200, height: 100)
		let inside = RiftFloatingGeometry.moved(
			start, by: CGSize(width: 50, height: 40), in: area, snaps: false)
		#expect(inside.origin == CGPoint(x: 150, y: 140))
		let past = RiftFloatingGeometry.moved(
			start, by: CGSize(width: -220, height: 0), in: area, snaps: false)
		// 120pt past the left edge: 24 × (1 − e^−1) ≈ 15.2pt beyond it.
		#expect(abs(past.minX - (-24 * (1 - exp(-1)))) < 0.0001)
		let far = RiftFloatingGeometry.moved(start, by: CGSize(width: -10_000, height: 0), in: area)
		#expect(far.minX > -24.0001)
	}

	@Test func movesSnapToNearEdges() {
		let start = CGRect(x: 100, y: 100, width: 200, height: 100)
		let snapped = RiftFloatingGeometry.moved(start, by: CGSize(width: -92, height: 0), in: area)
		#expect(snapped.minX == 0)  // 8pt from the edge
		let free = RiftFloatingGeometry.moved(start, by: CGSize(width: -80, height: 0), in: area)
		#expect(free.minX == 20)
	}

	@Test func resizingKeepsTheMinimumAndTheArea() {
		let start = CGRect(x: 100, y: 100, width: 400, height: 300)
		let shrunk = RiftFloatingGeometry.resized(
			start, edges: [.right, .bottom], by: CGSize(width: -1000, height: -1000), in: area)
		#expect(shrunk.size == CGSize(width: 240, height: 150))
		let grown = RiftFloatingGeometry.resized(
			start, edges: .left, by: CGSize(width: -500, height: 0), in: area)
		#expect(grown.minX == 0 && grown.maxX == 500)
	}

	@Test func unitRectsRoundTrip() {
		let frame = CGRect(x: 250, y: 200, width: 500, height: 400)
		let unit = RiftFloatingGeometry.unit(frame, in: area)
		#expect(unit == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
		#expect(RiftFloatingGeometry.absolute(unit, in: area) == frame)
	}

	@Test func shadows() {
		#expect(RiftFloatingShadow.resting == RiftFloatingShadow(opacity: 0.14, radius: 10, y: 3))
		#expect(RiftFloatingShadow.active == RiftFloatingShadow(opacity: 0.28, radius: 40, y: 20))
	}
}

/// A container smaller than the panes' minimum sizes: nothing goes negative or leaves the bounds.
@Suite struct SmallContainerTests {
	private func grid() -> RiftLayout<String> {
		var layout = RiftLayout<String>.pane("a")
		layout = layout.splitting("a", with: "b", edge: .right) ?? layout
		layout = layout.splitting("a", with: "c", edge: .bottom) ?? layout
		layout = layout.splitting("b", with: "d", edge: .bottom) ?? layout
		return layout
	}

	@Test func panesShrinkToNothingWithoutGoingNegative() {
		for size in [CGSize(width: 40, height: 30), CGSize(width: 5, height: 5), .zero] {
			let bounds = CGRect(origin: .zero, size: size)
			let geometry = grid().geometry(in: bounds)
			#expect(geometry.paneFrames.count == 4)
			for frame in geometry.paneFrames.values {
				#expect(frame.width >= 0 && frame.height >= 0)
				#expect(frame.minX >= 0 && frame.minY >= 0)
				#expect(frame.maxX <= size.width + 0.5 && frame.maxY <= size.height + 0.5)
				#expect(frame.width.isFinite && frame.height.isFinite)
			}
		}
	}

	@Test func dividerDragsStayInRangeBelowTheMinimumSizes() {
		// 200pt for two panes that each want 160: the limits scale down, and the divider can
		// still only move between them.
		let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
		let layout = RiftLayout<String>.pane("a").splitting("a", with: "b", edge: .right)!
		let geometry = layout.geometry(in: bounds)
		let divider = geometry.dividers[0]
		let hit = RiftDividerHit(dividers: [divider])
		for x in [-500.0, 0, 100, 200, 900] {
			var drag = RiftDividerDrag(hit: hit, pointer: CGPoint(x: 100, y: 50))
			let result = drag.update(
				pointer: CGPoint(x: x, y: 50), geometry: geometry, metrics: RiftMetrics())
			for update in result.updates {
				#expect(update.position >= 0 && update.position <= 1)
				#expect(update.position.isFinite)
			}
		}
	}

	@Test func floatingLayersFollowATinyArea() {
		let area = CGRect(x: 0, y: 0, width: 100, height: 60)
		let new = RiftFloatingGeometry.newBounds(for: nil, in: area, existing: [])
		#expect(area.contains(new))
		let resized = RiftFloatingGeometry.resized(
			new, edges: [.right, .bottom], by: CGSize(width: -500, height: -500), in: area)
		#expect(resized.width >= 0 && resized.height >= 0 && area.contains(resized))
		let frames = RiftFloatingGeometry.capsuleFrames(widths: [120, 120], in: area)
		#expect(frames.count == 2)
	}
}

