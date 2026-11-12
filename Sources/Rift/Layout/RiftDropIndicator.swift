import AppKit
import RiftCore

/// Shows where a dragged pane will land: a translucent accent fill with a solid 2pt outline.
final class RiftDropIndicatorView: RiftFlippedView {
	var color: NSColor? { didSet { needsDisplay = true } }
	var cornerRadius: CGFloat = 8 { didSet { needsDisplay = true } }

	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override func draw(_ dirtyRect: NSRect) {
		let accent = color ?? .controlAccentColor
		let fill = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
		accent.withAlphaComponent(0.25).setFill()
		fill.fill()
		let inner = bounds.insetBy(dx: 1, dy: 1)
		guard inner.width > 0, inner.height > 0 else { return }
		let radius = max(0, cornerRadius - 1)
		let stroke = NSBezierPath(roundedRect: inner, xRadius: radius, yRadius: radius)
		stroke.lineWidth = 2
		accent.setStroke()
		stroke.stroke()
	}
}

/// A borderless child window that shows the drop highlight above everything in its parent,
/// including glass and other views' layers.
final class RiftDropOverlayWindow: NSPanel {
	let indicator = RiftDropIndicatorView()

	init() {
		super.init(
			contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
			defer: true)
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		ignoresMouseEvents = true
		isReleasedWhenClosed = false
		collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
		indicator.autoresizingMask = [.width, .height]
		contentView = indicator
	}

	/// Shows the highlight over `screenRect` above `parent`, or hides it.
	func show(_ screenRect: CGRect?, above parent: NSWindow?) {
		guard let screenRect, let parent else {
			self.parent?.removeChildWindow(self)
			orderOut(nil)
			return
		}
		if self.parent !== parent {
			self.parent?.removeChildWindow(self)
			parent.addChildWindow(self, ordered: .above)
		}
		setFrame(screenRect, display: true)
		indicator.needsDisplay = true
		orderFront(nil)
	}
}
