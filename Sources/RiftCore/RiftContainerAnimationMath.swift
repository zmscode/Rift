import CoreGraphics

/// Maths for resize notices sent to pane content before the layout animates to a new width.
public enum RiftContainerAnimationMath {
	/// Predicts a pane's size once a container width animation finishes.
	///
	/// The pane takes a share of `widthChange` equal to its fraction of `contentWidth`
	/// (clamped to 0…1); its height doesn't change. Returns `nil` when `contentWidth` isn't
	/// positive or the result would be smaller than 1×1.
	///
	/// - Parameters:
	///   - paneSize: the pane's current size.
	///   - contentWidth: the container's width before the animation.
	///   - widthChange: target container width minus `contentWidth`.
	public static func predictedSize(
		paneSize: CGSize, contentWidth: CGFloat, widthChange: CGFloat
	) -> CGSize? {
		guard contentWidth > 0 else { return nil }
		let share = min(max(paneSize.width / contentWidth, 0), 1)
		let width = paneSize.width + widthChange * share
		guard width >= 1, paneSize.height >= 1 else { return nil }
		return CGSize(width: width, height: paneSize.height)
	}
}
