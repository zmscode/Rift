import Foundation

/// The easing of a layout animation: a cubic bezier, or a spring that runs for its own settling time.
public struct RiftMotionCurve: Hashable, Sendable {
	public struct Spring: Hashable, Sendable {
		/// √(stiffness / mass), in radians per second.
		public var naturalFrequency: Double
		/// damping / (2 · mass), per second.
		public var decayRate: Double
		/// Seconds until the spring is within `epsilon` of rest (both position and velocity).
		public var settlingDuration: Double
	}

	public enum Shape: Hashable, Sendable {
		case bezier(x1: Double, y1: Double, x2: Double, y2: Double)
		case spring(Spring)
	}

	public var shape: Shape

	public init(shape: Shape) { self.shape = shape }

	/// A cubic bezier from (0, 0) to (1, 1). `x1` and `x2` are clamped to 0…1. A non-finite value
	/// becomes 0 for the first point and 1 for the second.
	public static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Self {
		func clampX(_ x: Double, fallback: Double) -> Double {
			x.isFinite ? min(max(x, 0), 1) : fallback
		}
		return Self(
			shape: .bezier(
				x1: clampX(x1, fallback: 0), y1: y1.isFinite ? y1 : 0,
				x2: clampX(x2, fallback: 1), y2: y2.isFinite ? y2 : 1))
	}

	/// A damped spring. Mass and stiffness fall back to 1 and damping to 0 when they aren't
	/// usable. The settling time is the first millisecond step at which the spring is within
	/// `epsilon` of rest, capped at 10 seconds.
	public static func spring(
		mass: Double = 1, stiffness: Double, damping: Double, epsilon: Double = 0.001
	) -> Self {
		let m = mass.isFinite && mass > 0 ? mass : 1
		let k = stiffness.isFinite && stiffness > 0 ? stiffness : 1
		let c = damping.isFinite && damping >= 0 ? damping : 0
		let omega = (k / m).squareRoot()
		let decay = c / (2 * m)
		let settling = Self.settlingDuration(omega: omega, decay: decay, epsilon: epsilon)
		return Self(
			shape: .spring(
				Spring(naturalFrequency: omega, decayRate: decay, settlingDuration: settling)))
	}

	/// Critically damped, no overshoot (stiffness 1000, damping 2√1000). Settles in about 0.41s.
	public static let snappy = spring(stiffness: 1000, damping: 2 * 1000.0.squareRoot())
	/// A slight overshoot (stiffness 340, damping 28.95, damping ratio ≈0.785). Settles in about 0.54s.
	public static let natural = spring(stiffness: 340, damping: 28.95)
	/// Natural for chrome such as a sidebar fold or zoom (stiffness 340, damping ratio 0.85).
	public static let naturalChrome = spring(stiffness: 340, damping: 31.346451154795815)
	/// The default curve when none is configured.
	public static let standard = bezier(0.2, 0.9, 0.3, 1)
	public static let linear = bezier(0, 0, 1, 1)
	/// Used for pop-in fades.
	public static let fade = bezier(0.5, 0.5, 0.75, 1)
	/// Used for focus border crossfades.
	public static let crossfade = bezier(0.23, 1, 0.32, 1)

	/// The spring's settling time, or `nil` for a bezier.
	public var settlingDuration: Double? {
		if case .spring(let spring) = shape { return spring.settlingDuration }
		return nil
	}

	/// How long a transition on this curve takes: a spring's settling time, else 0.54 seconds.
	public var transitionDuration: Double { settlingDuration ?? 0.54 }

	/// How long the focus border takes to glide between panes on this curve: half the transition
	/// time (0.27 seconds for a bezier).
	public var borderGlideDuration: Double { settlingDuration.map { $0 / 2 } ?? 0.27 }

	/// Progress (0 at the start, 1 at rest; a spring can overshoot) after `elapsed` seconds of a
	/// transition lasting `duration`. Springs follow their own clock and use `duration` only to
	/// decide when to stop.
	public func progress(elapsed: Double, duration: Double) -> Double {
		guard duration > 0, elapsed < duration else { return 1 }
		let t = max(elapsed, 0)
		switch shape {
		case .bezier(let x1, let y1, let x2, let y2):
			return Self.bezierY(forX: t / duration, x1: x1, y1: y1, x2: x2, y2: y2)
		case .spring(let spring):
			return 1 - Self.displacement(spring: spring, t: t).x
		}
	}

	// MARK: Maths

	/// Displacement from rest and velocity of a unit step released at t = 0 with no velocity.
	static func displacement(omega: Double, decay: Double, t: Double) -> (x: Double, v: Double) {
		let disc = omega * omega - decay * decay
		if abs(disc) <= 1e-9 {
			let e = exp(-omega * t)
			return ((1 + omega * t) * e, omega * omega * t * e)
		} else if disc > 0 {
			let wd = disc.squareRoot()
			let e = exp(-decay * t)
			return (
				e * (cos(wd * t) + decay / wd * sin(wd * t)),
				e * (omega * omega / wd) * sin(wd * t)
			)
		} else {
			let r = (-disc).squareRoot()
			let r1 = -decay + r
			let r2 = -decay - r
			let x = (r1 * exp(r2 * t) - r2 * exp(r1 * t)) / (r1 - r2)
			let v = r1 * r2 * (exp(r1 * t) - exp(r2 * t)) / (r1 - r2)
			return (x, v)
		}
	}

	static func displacement(spring: Spring, t: Double) -> (x: Double, v: Double) {
		displacement(omega: spring.naturalFrequency, decay: spring.decayRate, t: t)
	}

	static func settlingDuration(omega: Double, decay: Double, epsilon: Double) -> Double {
		var t = 0.001
		while t <= 10 {
			let (x, v) = displacement(omega: omega, decay: decay, t: t)
			if abs(x) <= epsilon && abs(v) <= epsilon { return t }
			t += 0.001
		}
		return 10
	}

	static func bezierY(forX x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
		func coord(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
			let u = 1 - s
			return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
		}
		func slope(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
			let u = 1 - s
			return 3 * u * u * p1 + 6 * u * s * (p2 - p1) + 3 * s * s * (1 - p2)
		}
		// Newton's method, then bisection if it doesn't converge.
		var s = x
		for _ in 0..<8 {
			let error = coord(s, x1, x2) - x
			if abs(error) < 1e-7 { return coord(s, y1, y2) }
			let d = slope(s, x1, x2)
			if abs(d) < 1e-6 { break }
			s -= error / d
		}
		var low = 0.0
		var high = 1.0
		s = x
		for _ in 0..<40 {
			let value = coord(s, x1, x2)
			if abs(value - x) < 1e-7 { break }
			if value < x { low = s } else { high = s }
			s = (low + high) / 2
		}
		return coord(s, y1, y2)
	}
}

/// A duration and the curve it runs on.
public struct RiftMotionTiming: Hashable, Sendable {
	public var duration: Double
	public var curve: RiftMotionCurve

	public init(duration: Double, curve: RiftMotionCurve) {
		self.duration = duration
		self.curve = curve
	}

	public func progress(elapsed: Double) -> Double {
		curve.progress(elapsed: elapsed, duration: duration)
	}
}

/// The overall feel of layout motion.
public enum RiftAnimationStyle: String, Codable, Sendable, Hashable, CaseIterable {
	/// Settles quickly without bouncing.
	case snappy
	/// Springs with a slight overshoot.
	case natural
	/// Panes move at once.
	case off

	/// The curve panes move on, or `nil` when motion is off.
	public var paneCurve: RiftMotionCurve? {
		switch self {
		case .snappy: .snappy
		case .natural: .natural
		case .off: nil
		}
	}

	/// The curve for window chrome such as a sidebar fold, or `nil` when motion is off.
	public var chromeCurve: RiftMotionCurve? {
		switch self {
		case .snappy: .snappy
		case .natural: .naturalChrome
		case .off: nil
		}
	}
}

extension RiftMotionTiming {
	/// The focus border crossfade: 0.539 seconds × `timeScale` on `RiftMotionCurve.crossfade`.
	public static func borderCrossfade(timeScale: Double = 1) -> Self {
		Self(duration: 0.539 * timeScale, curve: .crossfade)
	}
}

/// How panes appear and disappear: they scale between `scale` and full size while fading.
public struct RiftPanePopIn: Hashable, Sendable {
	public var scale: Double
	public var entry: RiftMotionTiming
	public var exit: RiftMotionTiming
	public var fadeIn: RiftMotionTiming
	public var fadeOut: RiftMotionTiming

	public init(
		scale: Double, entry: RiftMotionTiming, exit: RiftMotionTiming,
		fadeIn: RiftMotionTiming, fadeOut: RiftMotionTiming
	) {
		self.scale = scale
		self.entry = entry
		self.exit = exit
		self.fadeIn = fadeIn
		self.fadeOut = fadeOut
	}

	/// The default pop-in for panes moving on `curve`, with every duration multiplied by
	/// `timeScale`: scale 0.87; the entry follows `curve` for its transition duration; exit 0.149s
	/// linear; fade in 0.173s and fade out 0.146s on the fade curve.
	public static func standard(entryCurve curve: RiftMotionCurve, timeScale: Double = 1) -> Self {
		Self(
			scale: 0.87,
			entry: RiftMotionTiming(duration: timeScale * curve.transitionDuration, curve: curve),
			exit: RiftMotionTiming(duration: timeScale * 0.149, curve: .linear),
			fadeIn: RiftMotionTiming(duration: timeScale * 0.173, curve: .fade),
			fadeOut: RiftMotionTiming(duration: timeScale * 0.146, curve: .fade))
	}
}

/// Recognises a two-finger spread or pinch from magnify events.
///
/// The scale starts at 1 and is multiplied by `max(1 + magnification, 0.01)` for each event. At
/// 1.25 or more it is a spread; at 0.8 or less, a pinch. Each gesture is recognised at most once.
public struct RiftPinchRecognizer: Sendable {
	public enum Gesture: Sendable, Equatable {
		case spread
		case pinch
	}

	public private(set) var scale: Double = 1
	private var hasRecognized = false

	public init() {}

	/// Starts a new gesture.
	public mutating func begin() {
		scale = 1
		hasRecognized = false
	}

	/// Feeds one event's magnification; returns the gesture the first time one is recognised.
	public mutating func update(magnification: Double) -> Gesture? {
		guard !hasRecognized else { return nil }
		scale *= max(1 + magnification, 0.01)
		if scale >= 1.25 {
			hasRecognized = true
			return .spread
		}
		if scale <= 0.8 {
			hasRecognized = true
			return .pinch
		}
		return nil
	}
}
