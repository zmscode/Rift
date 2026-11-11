import AppKit
import SwiftUI

/// What a close confirmation is about.
public enum RiftCloseSubject: Sendable, Equatable {
	case pane
	case otherPanes

	var title: String {
		switch self {
		case .pane: "Did you mean to close this pane?"
		case .otherPanes: "Did you mean to close the other panes?"
		}
	}

	var confirmTitle: String {
		switch self {
		case .pane: "Close Pane"
		case .otherPanes: "Close Other Panes"
		}
	}
}

/// The card shown before closing panes that are busy: a title, a row per busy pane (click one
/// to go to it), and Cancel / Close. It floats in a child window over the layout, which is
/// dimmed except for the pane in question.
@MainActor
final class RiftCloseConfirmation {
	struct Row: Identifiable {
		let id: Int
		let text: String
		let goTo: () -> Void
	}

	/// At most this many busy panes are listed; the rest are counted.
	static let maximumRows = 3

	private var panel: NSPanel?
	private let dim = RiftSpotlightView()
	private var monitor: Any?
	private var onCancel: (() -> Void)?

	var isPresented: Bool { panel != nil }

	/// Shows the card over `spotlight` (in `host`'s coordinates).
	func present(
		subject: RiftCloseSubject, rows: [Row], in host: NSView, spotlight: CGRect,
		confirm: @escaping () -> Void, cancel: @escaping () -> Void
	) {
		dismiss()
		guard let window = host.window else { return confirm() }
		onCancel = cancel
		dim.frame = host.bounds
		dim.autoresizingMask = [.width, .height]
		dim.hole = spotlight
		host.addSubview(dim, positioned: .above, relativeTo: nil)

		let shown = Array(rows.prefix(Self.maximumRows))
		let content = RiftCloseCard(
			title: subject.title, rows: shown, hiddenCount: max(0, rows.count - shown.count),
			confirmTitle: subject.confirmTitle,
			cancel: { [weak self] in self?.finish(confirmed: false) },
			confirm: { [weak self] in
				self?.finish(confirmed: true)
				confirm()
			},
			goTo: { [weak self] row in
				self?.finish(confirmed: false)
				row.goTo()
			})
		let hosting = NSHostingView(rootView: content)
		let size = hosting.fittingSize
		let panel = NSPanel(
			contentRect: CGRect(origin: .zero, size: size),
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered, defer: true)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.isReleasedWhenClosed = false
		panel.contentView = hosting
		// Centred on the spotlit pane, near its top.
		let anchor = window.convertToScreen(host.convert(spotlight, to: nil))
		var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY - size.height - 48)
		if let screen = window.screen?.visibleFrame {
			origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
			origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
		}
		panel.setFrameOrigin(origin)
		window.addChildWindow(panel, ordered: .above)
		panel.alphaValue = 0
		panel.orderFront(nil)
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.18
			panel.animator().alphaValue = 1
			dim.animator().alphaValue = 1
		}
		self.panel = panel
		// Escape cancels, Return confirms, a click anywhere else cancels.
		monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) {
			[weak self] event in
			let isKey = event.type == .keyDown
			let keyCode = isKey ? event.keyCode : 0
			let window = event.window
			let swallow = MainActor.assumeIsolated { () -> Bool in
				guard let self, let panel = self.panel else { return false }
				if isKey {
					if keyCode == 53 {
						self.finish(confirmed: false)
						return true
					}
					if keyCode == 36 || keyCode == 76 {
						self.finish(confirmed: true)
						confirm()
						return true
					}
					return false
				}
				if window !== panel { self.finish(confirmed: false) }
				return false
			}
			return swallow ? nil : event
		}
	}

	func dismiss() {
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
		if let panel {
			panel.parent?.removeChildWindow(panel)
			panel.orderOut(nil)
		}
		panel = nil
		dim.removeFromSuperview()
		dim.alphaValue = 0
	}

	private func finish(confirmed: Bool) {
		let cancel = onCancel
		onCancel = nil
		dismiss()
		if !confirmed { cancel?() }
	}
}

/// Dims everything except `hole`.
final class RiftSpotlightView: NSView {
	var hole: CGRect = .zero { didSet { needsDisplay = true } }

	override init(frame: NSRect) {
		super.init(frame: frame)
		alphaValue = 0
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	override var isFlipped: Bool { true }
	override func hitTest(_ point: NSPoint) -> NSView? { nil }

	override func draw(_ dirtyRect: NSRect) {
		let path = NSBezierPath(rect: bounds)
		path.append(NSBezierPath(roundedRect: hole, xRadius: 8, yRadius: 8))
		path.windingRule = .evenOdd
		NSColor.black.withAlphaComponent(0.35).setFill()
		path.fill()
	}
}

struct RiftCloseCard: View {
	let title: String
	let rows: [RiftCloseConfirmation.Row]
	let hiddenCount: Int
	let confirmTitle: String
	let cancel: () -> Void
	let confirm: () -> Void
	let goTo: (RiftCloseConfirmation.Row) -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(title).font(.system(size: 13, weight: .semibold))
			VStack(alignment: .leading, spacing: 2) {
				ForEach(rows) { row in
					Button {
						goTo(row)
					} label: {
						HStack {
							Circle().fill(.orange).frame(width: 6, height: 6)
							Text(row.text).lineLimit(1)
							Spacer(minLength: 8)
							Image(systemName: "arrow.right.circle.fill").foregroundStyle(.secondary)
						}
						.padding(.horizontal, 8).padding(.vertical, 5)
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
				}
				if hiddenCount > 0 {
					Text("and \(hiddenCount) more").font(.system(size: 11)).foregroundStyle(
						.secondary
					)
					.padding(.horizontal, 8)
				}
			}
			HStack {
				Spacer()
				Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
				Button(confirmTitle, role: .destructive, action: confirm)
					.keyboardShortcut(.defaultAction)
			}
		}
		.font(.system(size: 12))
		.padding(14)
		.frame(width: 320)
		.background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
	}
}
