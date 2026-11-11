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
	///
	/// Calls may overlap, for example when a fold is reversed half-way: each one re-targets the
	/// panes from the current width, and only the `endContainerAnimation()` matching the last
	/// outstanding begin posts the end notice. That way an interrupted animation's completion
	/// handler can't end the one that replaced it.
	public func beginContainerAnimation(toWidth targetWidth: CGFloat) {
		guard let window else { return }
		containerAnimationDepth += 1
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
		guard let window, containerAnimationDepth > 0 else { return }
		containerAnimationDepth -= 1
		guard containerAnimationDepth == 0 else { return }
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
		if let liveResizeToken { NotificationCenter.default.removeObserver(liveResizeToken) }
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

	private var liveResizeToken: NSObjectProtocol?

	/// Clears the target size first, then releases the hold, unless the window is still being
	/// resized live, in which case the hold lasts until that ends.
	private func finish() {
		generation += 1
		if targetSize != nil {
			targetSize = nil
			onTargetSize?(nil)
		}
		guard isHolding else { return }
		if let window = view?.window, window.inLiveResize {
			guard liveResizeToken == nil else { return }
			liveResizeToken = NotificationCenter.default.addObserver(
				forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.releaseHoldAfterLiveResize() }
			}
			return
		}
		isHolding = false
		onHoldChange?(false)
	}

	private func releaseHoldAfterLiveResize() {
		if let token = liveResizeToken { NotificationCenter.default.removeObserver(token) }
		liveResizeToken = nil
		guard isHolding else { return }
		isHolding = false
		onHoldChange?(false)
	}
}

/// What a pane's content can know about how it is being presented.
public struct RiftPanePresentation: Equatable, Sendable {
	/// `false` while the layout is moving; content such as a terminal can wait for `true` before
	/// reporting its new size.
	public var isLayoutSettled: Bool
	/// How zoomed the pane is: 0 tiled, 1 filling the layout, in between while the zoom animates.
	public var zoomFraction: CGFloat
	/// The content's current size.
	public var contentSize: CGSize
	/// While the layout moves, the size the content will end at.
	public var targetSize: CGSize?
	/// The content's width when it differs from its pane's (content held at a pinned size).
	public var contentWidth: CGFloat?
	/// How much of the content is cut off past the pane's trailing edge (0 when it fits).
	public var hiddenTrailingWidth: CGFloat
	/// The size of the pane's surface (its frame).
	public var surfaceSize: CGSize?
	/// Room to keep clear at the start and end of a title row along the pane's top edge (for the
	/// window buttons and a sidebar's toggle). Lay your title out between them, as the built-in
	/// headers do.
	public var titleLeadingInset: CGFloat = 0
	public var titleTrailingInset: CGFloat = 0
	/// For a pane along the top of a headless window: the height of a row whose centre lines up
	/// with the window buttons. `nil` elsewhere.
	public var titleRowHeight: CGFloat?

	public init(
		isLayoutSettled: Bool, zoomFraction: CGFloat, contentSize: CGSize, targetSize: CGSize?,
		contentWidth: CGFloat? = nil, hiddenTrailingWidth: CGFloat = 0, surfaceSize: CGSize? = nil
	) {
		self.isLayoutSettled = isLayoutSettled
		self.zoomFraction = zoomFraction
		self.contentSize = contentSize
		self.targetSize = targetSize
		self.contentWidth = contentWidth
		self.hiddenTrailingWidth = hiddenTrailingWidth
		self.surfaceSize = surfaceSize
	}
}

/// Adopt to hear about a pane's presentation changes: in the pane's content view (it is told
/// automatically), or in any object registered with `RiftView.addPresentationObserver(_:for:)`.
@MainActor
public protocol RiftPanePresentationObserving: AnyObject {
	func riftPanePresentationDidChange(_ presentation: RiftPanePresentation)
}

/// Adopt in a view inside a pane to hide its own scrollers while the layout reshapes (Rift calls
/// it when `structuralActivity` becomes non-empty, and again 0.15s after it empties). Rift then
/// leaves that view's `NSScroller`s alone.
@MainActor
public protocol RiftScrollerSuppressing: AnyObject {
	func riftSetScrollersSuppressed(_ suppressed: Bool)
}

@MainActor
final class RiftWeakPresentationObserver {
	weak var observer: RiftPanePresentationObserving?
	init(_ observer: RiftPanePresentationObserving) { self.observer = observer }
}
