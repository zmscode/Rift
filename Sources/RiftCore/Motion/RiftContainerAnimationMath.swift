import CoreGraphics

/// Maths for resize notices sent to pane content before the layout animates to a new width.
public enum RiftContainerAnimationMath {
	/// The size a layout will have once a container width animation finishes.
	///
	/// The layout takes a share of `widthChange` equal to its fraction of `contentWidth`
	/// (clamped to 0…1), or all of it when `contentWidth` is unknown or not positive. Returns `nil`
	/// unless both sides of the result are positive.
	public static func targetLayoutSize(
		layoutSize: CGSize, contentWidth: CGFloat?, widthChange: CGFloat
	) -> CGSize? {
		var share: CGFloat = 1
		if let contentWidth, contentWidth > 0 {
			share = min(max(layoutSize.width / contentWidth, 0), 1)
		}
		let size = CGSize(width: layoutSize.width + widthChange * share, height: layoutSize.height)
		guard size.width > 0, size.height > 0 else { return nil }
		return size
	}

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
