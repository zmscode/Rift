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
