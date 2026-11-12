import AppKit
import RiftCore

/// A plain flipped view.
class RiftFlippedView: NSView {
	override var isFlipped: Bool { true }
}

/// Weak references to every live Rift view, so a pane drag can find drop targets in other windows.
@MainActor
enum RiftViewRegistry {
	private final class WeakBox {
		weak var view: NSView?
		init(_ view: NSView) { self.view = view }
	}

	private static var boxes: [WeakBox] = []

	static func register(_ view: NSView) {
		boxes.removeAll { $0.view == nil || $0.view === view }
		boxes.append(WeakBox(view))
	}

	static func unregister(_ view: NSView) {
		boxes.removeAll { $0.view == nil || $0.view === view }
	}

	static func views<V: NSView>(of type: V.Type) -> [V] {
		boxes.compactMap { $0.view as? V }
	}

	/// Every live view that takes pane drops outside a layout.
	static func paneDropTargets() -> [any RiftPaneDropAccepting] {
		boxes.compactMap { $0.view as? any RiftPaneDropAccepting }
	}
}
