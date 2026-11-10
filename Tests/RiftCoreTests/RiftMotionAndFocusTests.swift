import CoreGraphics
import Testing

@testable import RiftCore

@Suite struct DirectionalFocusTests {
	/// a | (b over c), with b taking the top 30%.
	private func layout() -> Layout {
		.split(
			RiftSplit(
				axis: .horizontal, position: 0.5, first: .pane("a"),
				second: .split(
					RiftSplit(axis: .vertical, position: 0.3, first: .pane("b"), second: .pane("c"))
				)))
	}

	@Test func unitRectsIgnoreDividers() {
		let rects = layout().unitRects()
		#expect(rects["a"] == CGRect(x: 0, y: 0, width: 0.5, height: 1))
		#expect(rects["c"] == CGRect(x: 0.5, y: 0.3, width: 0.5, height: 0.7))
	}

	@Test func closestTopLeftCornerWins() {
		// From a, both b and c lie to the right; b's corner (0.5, 0) is nearest a's (0, 0).
		#expect(layout().neighbor(of: "a", toward: .right) == "b")
	}

	@Test func candidatesNeedNotOverlap() {
		// Left column split into top and bottom; right column one tall pane... then from the
		// bottom-left pane, "up" finds the top-left pane only, and "right" finds the tall pane
		// even though only part of it overlaps.
		let l: Layout = .split(
			RiftSplit(
				axis: .horizontal,
				first: .split(RiftSplit(axis: .vertical, first: .pane("tl"), second: .pane("bl"))),
				second: .pane("r")))
		#expect(l.neighbor(of: "bl", toward: .up) == "tl")
		#expect(l.neighbor(of: "bl", toward: .right) == "r")
		// A pane that is diagonally past the edge still counts.
		let diagonal: Layout = .split(
			RiftSplit(
				axis: .vertical,
				first: .split(RiftSplit(axis: .horizontal, first: .pane("x"), second: .pane("y"))),
				second: .split(
					RiftSplit(
						axis: .horizontal, position: 0.8, first: .pane("z"), second: .pane("w")))))
		// From y (top right, x ≥ 0.5) going down, z (0, 0.5) and w (0.8, 0.5) both lie below;
		// w's corner is nearer y's corner (0.5, 0): 0.09 + 0.25 < 0.25 + 0.25.
		#expect(diagonal.neighbor(of: "y", toward: .down) == "w")
	}

	@Test func cornerDistanceBreaksSideBySideCandidates() {
		let l: Layout = .split(
			RiftSplit(
				axis: .vertical, first: .pane("top"),
				second: .split(RiftSplit(axis: .horizontal, first: .pane("p"), second: .pane("q"))))
		)
		// Going up from p or q, only top lies above.
		#expect(l.neighbor(of: "q", toward: .up) == "top")
		// From top going down: p's corner (0, 0.5) is closer than q's (0.5, 0.5).
		#expect(l.neighbor(of: "top", toward: .down) == "p")
	}

	@Test func wrapShiftsByOneLayout() {
		let l = layout()
		#expect(l.neighbor(of: "b", toward: .right) == nil)
		// Shifted one layout to the left, b's probe sits at x = -0.5, so a (corner 0, 0) is nearest.
		#expect(l.neighbor(of: "b", toward: .right, wraps: true) == "a")
		#expect(l.neighbor(of: "c", toward: .down, wraps: true) == "b")
	}

	@Test func closeFocusesPreviousThenNext() {
		let l = layout()
		#expect(l.removing(.pane("c"))?.preferredFocus == "b")
		#expect(l.removing(.pane("b"))?.preferredFocus == "a")
		#expect(l.removing(.pane("a"))?.preferredFocus == "b")
		// Removing a whole subtree looks before its first pane.
		let right = l.split(withID: l.splitIDs[1])!
		#expect(l.removing(.split(right.id))?.preferredFocus == "a")
	}
}

@Suite struct MoveTests {
	@Test func edgeMoveReusesTheCollapsedSplit() {
		let l: Layout = .split(
			RiftSplit(
				axis: .horizontal, position: 0.3, first: .pane("a"),
				second: .split(RiftSplit(axis: .vertical, first: .pane("b"), second: .pane("c")))))
		let collapsed = l.splitIDs[1]
		let moved = l.moving("c", to: "a", zone: .bottom)!
		#expect(moved.split(withID: collapsed)?.position == 0.5)
		#expect(moved.split(withID: collapsed)?.axis == .vertical)
		#expect(l.moving("a", to: "a", zone: .left) == nil)
	}
}

@Suite struct MotionTests {
	@Test func snappyIsCriticallyDamped() {
		guard case .spring(let spring) = RiftMotionCurve.snappy.shape else {
			Issue.record("not a spring")
			return
		}
		#expect(abs(spring.naturalFrequency - 1000.0.squareRoot()) < 1e-9)
		#expect(abs(spring.decayRate - spring.naturalFrequency) < 1e-9)
		#expect(abs(spring.settlingDuration - 0.409) < 0.002)
	}

	@Test func naturalOvershootsSlightly() {
		guard case .spring(let spring) = RiftMotionCurve.natural.shape else {
			Issue.record("not a spring")
			return
		}
		#expect(abs(spring.decayRate / spring.naturalFrequency - 0.785) < 0.001)
		#expect(abs(spring.settlingDuration - 0.543) < 0.002)
		let peak = stride(from: 0.0, through: 0.5, by: 0.005)
			.map {
				RiftMotionCurve.natural.progress(elapsed: $0, duration: spring.settlingDuration)
			}
			.max()!
		#expect(peak > 1 && peak < 1.03)
	}

	@Test func progressEndsAtOne() {
		for curve in [RiftMotionCurve.snappy, .natural, .standard, .linear, .fade] {
			#expect(curve.progress(elapsed: 0, duration: curve.transitionDuration) < 0.01)
			#expect(curve.progress(elapsed: 10, duration: curve.transitionDuration) == 1)
		}
		#expect(abs(RiftMotionCurve.linear.progress(elapsed: 0.25, duration: 1) - 0.25) < 1e-6)
		#expect(RiftMotionCurve.standard.transitionDuration == 0.54)
	}

	@Test func bezierClampsControlPoints() {
		#expect(RiftMotionCurve.bezier(-1, 2, 3, .nan).shape == .bezier(x1: 0, y1: 2, x2: 1, y2: 1))
	}

	@Test func popInDefaults() {
		let pop = RiftPanePopIn.standard(entryCurve: .snappy)
		#expect(pop.scale == 0.87)
		#expect(pop.entry.duration == RiftMotionCurve.snappy.settlingDuration)
		#expect(pop.exit == RiftMotionTiming(duration: 0.149, curve: .linear))
		#expect(pop.fadeIn == RiftMotionTiming(duration: 0.173, curve: .fade))
		#expect(pop.fadeOut == RiftMotionTiming(duration: 0.146, curve: .fade))
		#expect(RiftPanePopIn.standard(entryCurve: .standard, timeScale: 2).entry.duration == 1.08)
	}

	@Test func borderTimings() {
		#expect(abs(RiftMotionCurve.snappy.borderGlideDuration - RiftMotionCurve.snappy.settlingDuration! / 2) < 1e-12)
		#expect(RiftMotionCurve.standard.borderGlideDuration == 0.27)
		#expect(RiftMotionTiming.borderCrossfade() == RiftMotionTiming(duration: 0.539, curve: .bezier(0.23, 1, 0.32, 1)))
	}

	@Test func styles() {
		#expect(RiftAnimationStyle.snappy.paneCurve == .snappy)
		#expect(RiftAnimationStyle.natural.paneCurve == .natural)
		#expect(RiftAnimationStyle.natural.chromeCurve == .naturalChrome)
		#expect(RiftAnimationStyle.off.paneCurve == nil)
	}
}
