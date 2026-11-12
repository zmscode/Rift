import AppKit
import RiftCore

/// Hosts one pane: an optional header, the content, and the focus border.
final class RiftPaneContainerView: RiftFlippedView {
	let header = RiftPaneHeaderView()
	let contentClip = RiftFlippedView()
	let strip = RiftPaneDragStripView()
	let border = RiftFocusBorderView()
	private(set) var contentView: NSView
	/// The pane's surface (background, glass, fills), behind the content.
	private(set) var surfaceView: NSView?
	/// The provider `surfaceView` came from, to tell whether it must be rebuilt.
	var surfaceSource: RiftPaneSurfaces?
	var hasCustomSurface = false

	func setSurfaceView(_ view: NSView?) {
		surfaceView?.removeFromSuperview()
		surfaceView = view
		guard let view else { return }
		view.frame = bounds
		view.autoresizingMask = [.width, .height]
		addSubview(view, positioned: .below, relativeTo: contentClip)
	}

	var headerHeight: CGFloat = 24 { didSet { layoutParts() } }
	/// Space kept above the content when there is no header bar.
	var headerlessTopInset: CGFloat = 0 { didSet { layoutParts() } }
	var showsHeader = true {
		didSet {
			header.isHidden = !showsHeader
			strip.isHidden = showsHeader
			header.needsLayout = true
			strip.needsLayout = true
			layoutParts()
		}
	}
	var cornerRadius: CGFloat = 0 {
		didSet {
			layer?.cornerRadius = cornerRadius
			layer?.masksToBounds = cornerRadius > 0
			border.cornerRadius = cornerRadius
		}
	}
	var inactiveAlpha: CGFloat = 1 { didSet { updateFocusAppearance() } }
	var activeAlpha: CGFloat = 1 { didSet { updateFocusAppearance() } }
	var isFocused = false { didSet { updateFocusAppearance() } }

	/// The pane's opacity is the product of these: a pane being dragged, a layout motion (growth
	/// or a visibility fade), and a pop in or out.
	var dragAlpha: CGFloat = 1 { didSet { refreshAlpha() } }
	var motionAlpha: CGFloat = 1 { didSet { refreshAlpha() } }
	var popAlpha: CGFloat = 1 { didSet { refreshAlpha() } }
	private func refreshAlpha() {
		let alpha = dragAlpha * motionAlpha * popAlpha
		if alphaValue != alpha { alphaValue = alpha }
	}

	init(content: NSView) {
		contentView = content
		super.init(frame: .zero)
		wantsLayer = true
		autoresizesSubviews = true
		header.autoresizingMask = [.width]
		strip.autoresizingMask = [.width]
		strip.isHidden = true
		contentClip.autoresizingMask = [.width, .height]
		border.autoresizingMask = [.width, .height]
		addSubview(contentClip)
		addSubview(header)
		addSubview(strip)
		addSubview(border)
		install(content)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	private func install(_ content: NSView) {
		contentClip.wantsLayer = true
		content.removeFromSuperview()
		content.translatesAutoresizingMaskIntoConstraints = true
		content.autoresizingMask = [.width, .height]
		content.frame = contentClip.bounds
		contentClip.addSubview(content)
	}

	/// Removes the content so it can be adopted by another container.
	func detachContent() -> NSView {
		contentView.removeFromSuperview()
		return contentView
	}

	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		layoutParts()
	}

	/// While set, the content keeps this pane size (top-left aligned, clipped) instead of following
	/// the container, so it reflows once rather than on every animation frame. A container
	/// (sidebar) animation's size wins over a layout motion's.
	var containerPinnedSize: CGSize? {
		didSet { if containerPinnedSize != oldValue { layoutParts() } }
	}
	var motionPinnedSize: CGSize? { didSet { if motionPinnedSize != oldValue { layoutParts() } } }
	var pinnedPaneSize: CGSize? { containerPinnedSize ?? motionPinnedSize }

	private func layoutParts() {
		let h =
			showsHeader ? min(headerHeight, bounds.height) : min(headerlessTopInset, bounds.height)
		header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
		contentClip.frame = CGRect(
			x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
		contentClip.layer?.masksToBounds = pinnedPaneSize != nil
		if let pinned = pinnedPaneSize {
			contentView.autoresizingMask = []
			contentView.frame = CGRect(
				x: 0, y: 0, width: pinned.width, height: max(0, pinned.height - h))
		} else {
			contentView.autoresizingMask = [.width, .height]
			contentView.frame = contentClip.bounds
		}
		// Without a header bar the strip floats over the top of the content.
		strip.frame = CGRect(
			x: 0, y: 0, width: bounds.width, height: min(headerHeight, bounds.height))
		border.frame = bounds
	}

	private func updateFocusAppearance() {
		border.isFocused = isFocused
		header.isFocused = isFocused
		contentClip.alphaValue = isFocused ? activeAlpha : inactiveAlpha
	}

	override func isAccessibilityElement() -> Bool { true }
	override func accessibilityRole() -> NSAccessibility.Role? { .group }
	override func accessibilityLabel() -> String? { header.title }
}
