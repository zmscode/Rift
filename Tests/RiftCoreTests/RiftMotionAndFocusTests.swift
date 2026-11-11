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

@Suite struct SwapNeighborTests {
	private let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
	private let metrics = RiftMetrics(dividerThickness: 0, minimumPaneSize: .zero, displayScale: 0)

	@Test func overlappingCandidatesWin() {
		// tl / bl on the left, one tall pane on the right: from bl, right is the tall pane.
		let l: Layout = .split(
			RiftSplit(
				axis: .horizontal,
				first: .split(RiftSplit(axis: .vertical, first: .pane("tl"), second: .pane("bl"))),
				second: .pane("r")))
		#expect(l.swapNeighbor(of: "bl", toward: .right, in: bounds, metrics: metrics) == "r")
		#expect(l.swapNeighbor(of: "r", toward: .left, in: bounds, metrics: metrics) == "tl")
		#expect(l.swapNeighbor(of: "tl", toward: .left, in: bounds, metrics: metrics) == nil)
	}

	@Test func smallerGapThenLayoutOrder() {
		// a | b | c: from c going left, b (gap 0) beats a.
		let l: Layout = .split(
			RiftSplit(
				axis: .horizontal, position: 1.0 / 3, first: .pane("a"),
				second: .split(RiftSplit(axis: .horizontal, first: .pane("b"), second: .pane("c"))))
		)
		#expect(l.swapNeighbor(of: "c", toward: .left, in: bounds, metrics: metrics) == "b")
		// top / (p | q): from top going down both overlap with gap 0; p comes first.
		let m: Layout = .split(
			RiftSplit(
				axis: .vertical, first: .pane("top"),
				second: .split(RiftSplit(axis: .horizontal, first: .pane("p"), second: .pane("q"))))
		)
		#expect(m.swapNeighbor(of: "top", toward: .down, in: bounds, metrics: metrics) == "p")
	}

	@Test func crossingPoint() {
		let l: Layout = .split(
			RiftSplit(
				axis: .horizontal, position: 0.5,
				first: .split(
					RiftSplit(axis: .vertical, position: 0.5, first: .pane("a"), second: .pane("b"))
				),
				second: .split(
					RiftSplit(axis: .vertical, position: 0.5, first: .pane("c"), second: .pane("d"))
				)))
		let hit = l.geometry(
			in: bounds,
			metrics: RiftMetrics(dividerThickness: 2, minimumPaneSize: .zero, displayScale: 0)
		)
		.dividerHit(at: CGPoint(x: 147, y: 99), hitThickness: 16)
		#expect(hit?.isIntersection == true)
		#expect(hit?.crossingPoint.map { abs($0.x - 150) < 1.5 && abs($0.y - 100) < 1.5 } == true)
	}
}

@Suite struct PinchTests {
	@Test func spreadAndPinchThresholds() {
		var r = RiftPinchRecognizer()
		r.begin()
		#expect(r.update(magnification: 0.1) == nil)  // 1.1
		#expect(r.update(magnification: 0.1) == nil)  // 1.21
		#expect(r.update(magnification: 0.04) == .spread)  // 1.258
		#expect(r.update(magnification: 0.5) == nil)  // once per gesture
		r.begin()
		#expect(r.update(magnification: -0.1) == nil)  // 0.9
		#expect(r.update(magnification: -0.12) == .pinch)  // 0.792
	}

	@Test func scaleNeverCollapses() {
		var r = RiftPinchRecognizer()
		r.begin()
		#expect(r.update(magnification: -5) == .pinch)
		#expect(r.scale == 0.01)
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
		#expect(
			abs(
				RiftMotionCurve.snappy.borderGlideDuration - RiftMotionCurve.snappy
					.settlingDuration! / 2) < 1e-12)
		#expect(RiftMotionCurve.standard.borderGlideDuration == 0.27)
		#expect(
			RiftMotionTiming.borderCrossfade()
				== RiftMotionTiming(duration: 0.539, curve: .bezier(0.23, 1, 0.32, 1)))
	}

	@Test func styles() {
		#expect(RiftAnimationStyle.snappy.paneCurve == .snappy)
		#expect(RiftAnimationStyle.natural.paneCurve == .natural)
		#expect(RiftAnimationStyle.natural.chromeCurve == .naturalChrome)
		#expect(RiftAnimationStyle.off.paneCurve == nil)
	}
}
