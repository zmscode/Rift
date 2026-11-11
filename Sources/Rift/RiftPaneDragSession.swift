import AppKit
import RiftCore

/// One pane drag: shows a floating preview, finds the drop target under the pointer across all
/// Rift views in the same group, and applies the drop.
@MainActor
final class RiftPaneDragSession<PaneID: Hashable & Sendable> {
	private weak var source: RiftView<PaneID>?
	private let pane: PaneID
	private let panel: NSPanel
	private var current: (view: RiftView<PaneID>, target: RiftDropTarget<PaneID>)?

	init?(source: RiftView<PaneID>, pane: PaneID, grabPoint: CGPoint) {
		guard let frame = source.frame(of: pane), frame.width > 0, frame.height > 0 else {
			return nil
		}
		self.source = source
		self.pane = pane

		let maxSize = source.configuration.dragPreviewMaxSize
		// The host's own preview view, sized to fit; else a scaled snapshot of the pane.
		let custom = source.makeDragPreview?(pane)
		let size: CGSize
		if let custom {
			let fitting = custom.fittingSize
			size =
				fitting.width > 0 && fitting.height > 0
				? CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))
				: maxSize
		} else {
			let scale = min(1, maxSize.width / frame.width, maxSize.height / frame.height)
			size = CGSize(
				width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded())
		}
		panel = NSPanel(
			contentRect: CGRect(origin: .zero, size: size),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: true)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.level = .floating
		panel.ignoresMouseEvents = true
		panel.isReleasedWhenClosed = false
		panel.collectionBehavior = [.transient, .ignoresCycle]

		if let custom {
			custom.frame = CGRect(origin: .zero, size: size)
			panel.contentView = custom
			source.setDragging(pane)
			return
		}
		let imageView = NSImageView(frame: CGRect(origin: .zero, size: size))
		imageView.image = source.snapshot(of: pane)
		imageView.imageScaling = .scaleAxesIndependently
		imageView.wantsLayer = true
		imageView.layer?.cornerRadius = 8
		imageView.layer?.masksToBounds = true
		imageView.layer?.borderWidth = 1
		imageView.layer?.borderColor = NSColor.separatorColor.cgColor
		imageView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
		panel.contentView = imageView

		source.setDragging(pane)
	}

	func move(to screenPoint: CGPoint) {
		let size = panel.frame.size
		// The preview hangs below and to the right of the pointer, 12pt away on each axis
		// (screen coordinates have y up).
		let origin = CGPoint(x: screenPoint.x + 12, y: screenPoint.y - size.height - 12)
		panel.setFrameOrigin(origin)
		if !panel.isVisible { panel.orderFront(nil) }

		let resolved = resolve(screenPoint)
		if let previous = current?.view, previous !== resolved.target?.view {
			previous.showDropIndicator(nil)
		}
		current = resolved.target
		current?.view.showDropIndicator(current?.target.indicator)
	}

	func drop(at screenPoint: CGPoint) {
		let resolved = resolve(screenPoint)
		finish()
		guard let source else { return }
		if let (view, target) = resolved.target {
			view.performDrop(of: pane, from: source, onto: target)
		} else if resolved.isOutsideApp {
			source.tearOut(pane, at: screenPoint)
		}
	}

	func cancel() { finish() }

	private func finish() {
		current?.view.showDropIndicator(nil)
		current = nil
		panel.orderOut(nil)
		source?.setDragging(nil)
	}

	/// The Rift view and drop location under `screenPoint`.
	private func resolve(_ screenPoint: CGPoint) -> (
		target: (view: RiftView<PaneID>, target: RiftDropTarget<PaneID>)?, isOutsideApp: Bool
	) {
		guard let source else { return (nil, false) }
		// The front-most window under the pointer (the preview panel ignores the mouse, so it's skipped).
		let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
		guard number > 0, NSApp.window(withWindowNumber: number) != nil else { return (nil, true) }
		let candidates = RiftViewRegistry.views(of: RiftView<PaneID>.self).filter {
			$0.groupIdentifier == source.groupIdentifier
				&& $0.window?.windowNumber == number
				&& !$0.isHiddenOrHasHiddenAncestor
		}
		for view in candidates {
			guard let window = view.window else { continue }
			let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
			if let target = view.dropTarget(at: point, pane: pane, from: source) {
				return ((view, target), false)
			}
		}
		return (nil, false)
	}
}
