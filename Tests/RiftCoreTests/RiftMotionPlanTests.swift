import CoreGraphics
import Foundation
import Testing

@testable import RiftCore

@Suite struct VisibilityFadeTests {
	@Test func hidingFadesOutOverTheFirstHalf() {
		let fade = RiftVisibilityFade(direction: .hiding)
		#expect(fade.opacity(progress: 0) == 1)
		#expect(abs(fade.opacity(progress: 0.25) - 0.5) < 1e-9)  // smoothstep(0.5) = 0.5
		#expect(fade.opacity(progress: 0.5) == 0)
		#expect(fade.opacity(progress: 0.9) == 0)
	}

	@Test func revealingHoldsThenFadesIn() {
		let fade = RiftVisibilityFade(direction: .revealing)
		#expect(fade.opacity(progress: 0.3) == 0)
		#expect(fade.opacity(progress: 0.5) == 0)
		#expect(abs(fade.opacity(progress: 0.75) - 0.5) < 1e-9)
		#expect(fade.opacity(progress: 1) == 1)
	}

	@Test func continuesFromItsStartOpacityAndPhase() {
		let fade = RiftVisibilityFade(direction: .revealing, phaseStart: 0.5, startOpacity: 0.4)
		// Already at the half-way point, so it starts rising at once from 0.4.
		#expect(fade.opacity(progress: 0) == 0.4)
		#expect(fade.opacity(progress: 1) == 1)
		#expect(fade.opacity(progress: 0.2) > 0.4)
	}
}

@Suite struct GrowthTransitionTests {
	let frame = CGRect(x: 100, y: 0, width: 400, height: 300)

	@Test func insertionStartsCollapsedAgainstItsEdge() {
		let growth = RiftGrowthTransition.inserting(frame, from: .right)
		#expect(growth.rawFrame(progress: 0) == CGRect(x: 500, y: 0, width: 0, height: 300))
		// Drawn at least 32pt long, flush with the right edge.
		#expect(growth.displayFrame(progress: 0) == CGRect(x: 468, y: 0, width: 32, height: 300))
		#expect(growth.displayFrame(progress: 1) == frame)
		#expect(growth.opacity(progress: 0, direction: .insertion) == 0)
		#expect(growth.opacity(progress: 1, direction: .insertion) == 1)
	}

	@Test func opacityFollowsTheLengthPastTheFirst32Points() {
		let growth = RiftGrowthTransition.inserting(frame, from: .left)
		// Raw length 32 at progress 0.08: nothing past the floor yet.
		#expect(growth.spatialOpacity(progress: 0.08) < 1e-9)
		// Half of the remaining 368pt: smoothstep(0.5) = 0.5.
		let half = (32 + 184) / 400.0
		#expect(abs(growth.spatialOpacity(progress: half) - 0.5) < 1e-9)
	}

	@Test func removalFadesWithItsLength() {
		let growth = RiftGrowthTransition.removing(frame, into: .bottom)
		#expect(growth.opacity(progress: 0, direction: .removal) == 1)
		#expect(growth.opacity(progress: 1, direction: .removal) == 0)
		#expect(growth.displayFrame(progress: 1) == CGRect(x: 100, y: 268, width: 400, height: 32))
	}

	@Test func shortPanesUseTheirWholeLength() {
		let small = CGRect(x: 0, y: 0, width: 20, height: 100)
		let growth = RiftGrowthTransition.inserting(small, from: .left)
		#expect(growth.displayFrame(progress: 0).width == 20)
		#expect(abs(growth.spatialOpacity(progress: 0.5) - 0.5) < 1e-9)
	}
}

@Suite struct PopStateTests {
	let style = RiftPanePopIn.standard(entryCurve: .linear)

	@Test func enteringGrowsFromThePopScale() {
		let state = RiftPopState(direction: .entering)
		#expect(state.scale(elapsed: 0, style: style) == 0.87)
		#expect(state.scale(elapsed: 10, style: style) == 1)
		#expect(state.opacity(elapsed: 0, style: style) == 0)
		#expect(state.opacity(elapsed: 10, style: style) == 1)
	}

	@Test func leavingShrinksAndFades() {
		let state = RiftPopState(direction: .leaving)
		#expect(state.scale(elapsed: 10, style: style) == 0.87)
		#expect(state.opacity(elapsed: 10, style: style) == 0)
		#expect(state.duration(style: style) == 0.149)
	}
}

@Suite struct DividerFadeTests {
	@Test func newLinesFadeInAndOldOnesOut() {
		let kept = UUID(), added = UUID(), removed = UUID()
		let result = riftDividerOpacities(
			from: [kept: 1, removed: 1], to: [kept: 1, added: 1], progress: 0.25)
		#expect(result[kept] == 1)
		#expect(result[added] == 0.25)
		#expect(result[removed] == 0.75)
	}
}

@Suite struct GrowthEdgeAndLineTests {
	@Test func growthEdgeIsTheOuterSideInTheParentSplit() {
		let layout = RiftLayout<String>.pane("a").splitting("a", with: "b", edge: .right)!
		#expect(layout.growthEdge(of: "b") == .right)
		#expect(layout.growthEdge(of: "a") == .left)
		let stacked = RiftLayout<String>.pane("a").splitting("a", with: "b", edge: .top)!
		#expect(stacked.growthEdge(of: "b") == .top)
		#expect(RiftLayout<String>.pane("a").growthEdge(of: "a") == nil)
	}

	@Test func aLineThickerThanTheGapOverlapsThePanes() {
		let layout = RiftLayout<String>.pane("a").splitting("a", with: "b", edge: .right)!
		let metrics = RiftMetrics(dividerThickness: 0, lineThickness: 1, displayScale: 1)
		let geometry = layout.geometry(
			in: CGRect(x: 0, y: 0, width: 400, height: 200), metrics: metrics)
		#expect(geometry.paneFrames["a"]?.maxX == geometry.paneFrames["b"]?.minX)
		let line = geometry.dividers[0].drawnLine
		#expect(line.width == 1)
		#expect(line.midX == 200)
	}
}
