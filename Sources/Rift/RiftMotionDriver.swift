import AppKit
import QuartzCore

/// Runs frame-by-frame animations from the view's display link, so springs can drive view frames.
///
/// Each track has a key. Starting a track with a key that is already running replaces it; the old
/// track's completion still runs.
@MainActor
final class RiftMotionDriver: NSObject {
	private struct Track {
		var start: CFTimeInterval
		var duration: Double
		var apply: (Double) -> Void
		var completion: (() -> Void)?
	}

	private weak var view: NSView?
	private var link: CADisplayLink?
	private var tracks: [AnyHashable: Track] = [:]

	init(view: NSView) {
		self.view = view
	}

	/// Calls `apply` with the elapsed seconds on every frame until `duration` has passed, then once
	/// more with `duration`, then `completion`.
	func run(
		_ key: AnyHashable, duration: Double, apply: @escaping (Double) -> Void,
		completion: (() -> Void)? = nil
	) {
		cancel(key, finishing: false)
		apply(0)
		guard duration > 0, let view, view.window != nil else {
			apply(max(duration, 0))
			completion?()
			return
		}
		tracks[key] = Track(
			start: CACurrentMediaTime(), duration: duration, apply: apply, completion: completion)
		if link == nil {
			let link = view.displayLink(target: self, selector: #selector(tick(_:)))
			link.add(to: .main, forMode: .common)
			self.link = link
		}
	}

	/// Stops a track. With `finishing`, it first jumps to its end state.
	func cancel(_ key: AnyHashable, finishing: Bool = true) {
		guard let track = tracks.removeValue(forKey: key) else { return }
		if finishing { track.apply(track.duration) }
		track.completion?()
		stopIfIdle()
	}

	func isRunning(_ key: AnyHashable) -> Bool { tracks[key] != nil }

	@objc private func tick(_ link: CADisplayLink) {
		let now = CACurrentMediaTime()
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		var finished: [AnyHashable] = []
		for (key, track) in tracks {
			let elapsed = now - track.start
			if elapsed >= track.duration {
				track.apply(track.duration)
				finished.append(key)
			} else {
				track.apply(elapsed)
			}
		}
		CATransaction.commit()
		for key in finished {
			// A completion may have started a new track under the same key.
			if let track = tracks[key], now - track.start >= track.duration {
				tracks[key] = nil
				track.completion?()
			}
		}
		stopIfIdle()
	}

	private func stopIfIdle() {
		guard tracks.isEmpty, let link else { return }
		link.invalidate()
		self.link = nil
	}
}

extension NSView {
	/// Scales the view's layer about its centre (1 = normal size).
	func rift_setPresentationScale(_ scale: CGFloat) {
		guard let layer else { return }
		if scale == 1 {
			layer.setAffineTransform(.identity)
			return
		}
		let size = bounds.size
		layer.setAffineTransform(
			CGAffineTransform(
				a: scale, b: 0, c: 0, d: scale,
				tx: size.width * (1 - scale) / 2, ty: size.height * (1 - scale) / 2))
	}
}
