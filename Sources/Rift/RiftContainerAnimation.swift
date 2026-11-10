import AppKit
import RiftCore

/// Resize notices for pane content.
///
/// Before a host animates a `RiftView` to a new width (for example when a sidebar folds), it calls
/// `beginContainerAnimation(toWidth:)`; when the animation is done it calls `endContainerAnimation()`.
/// Pane content that is expensive to reflow (terminals, editors) can listen with
/// `RiftContainerAnimationObserver` and either freeze until the end or resize once, straight to
/// its predicted final size, instead of reflowing on every frame.
public enum RiftContainerAnimation {
	/// Posted with `object:` set to the window. `userInfo` holds `contentWidthKey` (the width
	/// before the animation) and `widthChangeKey` (target width minus that width) as `NSNumber`s.
	public static let willBeginNotification = Notification.Name("Rift.containerAnimationWillBegin")
	/// Posted with `object:` set to the window and no `userInfo`.
	public static let didEndNotification = Notification.Name("Rift.containerAnimationDidEnd")
	public static let contentWidthKey = "contentWidth"
	public static let widthChangeKey = "widthChange"
	/// How long an observer waits for the end notice before giving up on its own.
	public static let safetyTimeout: TimeInterval = 2.0
}

extension RiftView {
	/// Announces that this view is about to animate to `targetWidth`. Does nothing outside a window.
	public func beginContainerAnimation(toWidth targetWidth: CGFloat) {
		guard let window else { return }
		let current = bounds.width
		NotificationCenter.default.post(
			name: RiftContainerAnimation.willBeginNotification,
			object: window,
			userInfo: [
				RiftContainerAnimation.contentWidthKey: NSNumber(value: Double(current)),
				RiftContainerAnimation.widthChangeKey: NSNumber(
					value: Double(targetWidth - current)),
			])
	}

	/// Announces that the width animation started with `beginContainerAnimation(toWidth:)` is over.
	public func endContainerAnimation() {
		guard let window else { return }
		NotificationCenter.default.post(
			name: RiftContainerAnimation.didEndNotification, object: window)
	}
}

/// What pane content does while its container animates to a new width.
public enum RiftResizeHandling: Sendable, Equatable {
	/// Ignore the notices.
	case off
	/// Freeze until the animation ends (`onHoldChange(true)`, then `onHoldChange(false)`).
	case holdContent
	/// Resize once, straight to the predicted final size (`onTargetSize`).
	case resizeToTarget
}

/// Listens for container animation notices on behalf of one piece of pane content.
///
/// Only notices whose `object` is `view`'s window are handled. Each "will begin" notice starts a
/// `RiftContainerAnimation.safetyTimeout` timer that ends the animation if the "did end" notice
/// never arrives.
@MainActor
public final class RiftContainerAnimationObserver {
	public weak var view: NSView?
	public var handling: RiftResizeHandling
	/// Called with `true` when content should freeze, and `false` when it may update again.
	public var onHoldChange: ((Bool) -> Void)?
	/// Called with the predicted final size, then with `nil` when the animation ends.
	public var onTargetSize: ((CGSize?) -> Void)?

	public private(set) var isHolding = false
	public private(set) var targetSize: CGSize?

	private var generation = 0
	private var tokens: [NSObjectProtocol] = []

	public init(view: NSView, handling: RiftResizeHandling = .holdContent) {
		self.view = view
		self.handling = handling
		let center = NotificationCenter.default
		tokens.append(
			center.addObserver(
				forName: RiftContainerAnimation.willBeginNotification, object: nil, queue: .main
			) { [weak self] note in
				let object = (note.object as AnyObject?).map(ObjectIdentifier.init)
				let contentWidth =
					(note.userInfo?[RiftContainerAnimation.contentWidthKey] as? NSNumber)?
					.doubleValue
				let widthChange =
					(note.userInfo?[RiftContainerAnimation.widthChangeKey] as? NSNumber)?
					.doubleValue
				MainActor.assumeIsolated {
					self?.willBegin(
						object: object, contentWidth: contentWidth, widthChange: widthChange)
				}
			})
		tokens.append(
			center.addObserver(
				forName: RiftContainerAnimation.didEndNotification, object: nil, queue: .main
			) { [weak self] note in
				let object = (note.object as AnyObject?).map(ObjectIdentifier.init)
				MainActor.assumeIsolated {
					guard let self, self.isOwnWindow(object) else { return }
					self.finish()
				}
			})
	}

	isolated deinit {
		tokens.forEach(NotificationCenter.default.removeObserver)
	}

	private func isOwnWindow(_ object: ObjectIdentifier?) -> Bool {
		guard let window = view?.window, let object else { return false }
		return object == ObjectIdentifier(window)
	}

	private func willBegin(object: ObjectIdentifier?, contentWidth: Double?, widthChange: Double?) {
		guard isOwnWindow(object), handling != .off else { return }
		generation += 1
		let started = generation
		DispatchQueue.main.asyncAfter(deadline: .now() + RiftContainerAnimation.safetyTimeout) {
			[weak self] in
			MainActor.assumeIsolated {
				guard let self, self.generation == started else { return }
				self.finish()
			}
		}
		switch handling {
		case .off:
			return
		case .holdContent:
			if !isHolding {
				isHolding = true
				onHoldChange?(true)
			}
		case .resizeToTarget:
			guard let view, let contentWidth, let widthChange else { return }
			let target = RiftContainerAnimationMath.predictedSize(
				paneSize: view.bounds.size, contentWidth: CGFloat(contentWidth),
				widthChange: CGFloat(widthChange))
			guard target != targetSize else { return }
			targetSize = target
			onTargetSize?(target)
		}
	}

	private func finish() {
		generation += 1
		if isHolding {
			isHolding = false
			onHoldChange?(false)
		}
		if targetSize != nil {
			targetSize = nil
			onTargetSize?(nil)
		}
	}
}
