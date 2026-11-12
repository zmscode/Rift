import AppKit
import RiftCore

extension RiftTabEasing {
	/// The timing curve for a non-spring easing.
	var timingFunction: CAMediaTimingFunction {
		switch self {
		case .production, .spring:
			let (a, b, c, d) = Self.productionControlPoints
			return CAMediaTimingFunction(controlPoints: a, b, c, d)
		case .linear: return CAMediaTimingFunction(name: .linear)
		case .easeIn: return CAMediaTimingFunction(name: .easeIn)
		case .easeOut: return CAMediaTimingFunction(name: .easeOut)
		case .easeInOut: return CAMediaTimingFunction(name: .easeInEaseOut)
		}
	}
}

/// Moves and fades tab bar views with a `RiftTabTiming`: springs settle in their own time, other
/// easings run for the timing's duration (at least 0.01s) on their curve.
@MainActor
enum RiftTabAnimator {
	/// Sets `view.frame`, animating from where it is drawn now.
	static func setFrame(_ view: NSView, _ frame: CGRect, timing: RiftTabTiming?) {
		guard view.frame != frame else { return }
		guard let timing, let layer = view.layer,
			!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
		else {
			view.layer?.removeAnimation(forKey: "rift.tab.position")
			view.layer?.removeAnimation(forKey: "rift.tab.bounds")
			view.frame = frame
			return
		}
		let from = layer.presentation() ?? layer
		let fromPosition = from.position
		let fromBounds = from.bounds
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		view.frame = frame
		CATransaction.commit()
		add(
			to: layer, keyPath: "position", from: NSValue(point: fromPosition),
			to: NSValue(point: layer.position), timing: timing)
		add(
			to: layer, keyPath: "bounds", from: NSValue(rect: fromBounds),
			to: NSValue(rect: layer.bounds), timing: timing)
	}

	/// Sets `view.alphaValue`, animating from what is drawn now.
	static func setAlpha(_ view: NSView, _ alpha: CGFloat, timing: RiftTabTiming?) {
		guard view.alphaValue != alpha else { return }
		guard let timing, let layer = view.layer else {
			view.alphaValue = alpha
			return
		}
		let from = (layer.presentation() ?? layer).opacity
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		view.alphaValue = alpha
		CATransaction.commit()
		add(to: layer, keyPath: "opacity", from: from, to: Float(alpha), timing: timing)
	}

	/// Sets a layer's opacity, animating from what is drawn now.
	static func setOpacity(_ layer: CALayer, _ opacity: Float, timing: RiftTabTiming?) {
		guard layer.opacity != opacity else { return }
		let from = (layer.presentation() ?? layer).opacity
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		layer.opacity = opacity
		CATransaction.commit()
		if let timing {
			add(to: layer, keyPath: "opacity", from: from, to: opacity, timing: timing)
		}
	}

	static func add(to layer: CALayer, keyPath: String, from: Any, to: Any, timing: RiftTabTiming) {
		let animation: CABasicAnimation
		if timing.easing == .spring {
			let spring = CASpringAnimation(keyPath: keyPath)
			spring.mass = RiftTabEasing.springMass
			spring.stiffness = RiftTabEasing.springStiffness
			spring.damping = RiftTabEasing.springDamping
			spring.initialVelocity = 0
			spring.duration = spring.settlingDuration
			animation = spring
		} else {
			animation = CABasicAnimation(keyPath: keyPath)
			animation.duration = max(timing.duration, 0.01)
			animation.timingFunction = timing.easing.timingFunction
		}
		animation.fromValue = from
		animation.toValue = to
		layer.add(animation, forKey: "rift.tab.\(keyPath)")
	}
}
