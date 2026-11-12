import AppKit
import Quartz
import Rift
import SwiftUI

/// Everything that happens, in a real `NSScrollView` that hides its scroller while the layout
/// reshapes (it adopts `RiftScrollerSuppressing`).
struct ActivityPane: View {
	@State private var scrollerHidden = false
	@Environment(\.riftThemeSelection) private var themeSelection
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		let theme = (themeSelection ?? .standard).theme(isDark: colorScheme == .dark)
		ActivityLogView(
			lines: Files.shared.log, text: NSColor(rift: theme[.contentSecondary]),
			highlight: NSColor(rift: theme[.terminalAnsi2]),
			onScrollerSuppressed: { scrollerHidden = $0 }
		)
		.overlay(alignment: .topTrailing) {
			if scrollerHidden {
				Text("scroller hidden").font(.system(size: 9, weight: .bold)).textCase(.uppercase)
					.padding(.horizontal, 6).padding(.vertical, 2)
					.background(Capsule().fill(.black.opacity(0.25)))
					.padding(8)
			}
		}
		.padding(.horizontal, 6)
		.padding(.bottom, 6)
	}
}

struct ActivityLogView: NSViewRepresentable {
	let lines: [String]
	let text: NSColor
	let highlight: NSColor
	let onScrollerSuppressed: (Bool) -> Void

	func makeNSView(context: Context) -> ActivityScrollView { ActivityScrollView() }

	func updateNSView(_ view: ActivityScrollView, context: Context) {
		view.onSuppressed = onScrollerSuppressed
		view.show(lines, text: text, highlight: highlight)
	}
}

final class ActivityScrollView: NSScrollView, RiftScrollerSuppressing {
	var onSuppressed: ((Bool) -> Void)?
	private let textView = NSTextView()
	private var shown: [String] = []
	private var colors: (NSColor, NSColor)?

	init() {
		super.init(frame: .zero)
		hasVerticalScroller = true
		scrollerStyle = .legacy
		drawsBackground = false
		textView.isEditable = false
		textView.drawsBackground = false
		textView.autoresizingMask = [.width]
		documentView = textView
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func show(_ lines: [String], text: NSColor, highlight: NSColor) {
		let recolour = colors.map { $0.0 != text || $0.1 != highlight } ?? true
		colors = (text, highlight)
		// The log only grows (or drops its oldest lines); rebuild when it doesn't simply extend.
		let extends =
			!recolour && lines.count >= shown.count && Array(lines.prefix(shown.count)) == shown
		let new = extends ? Array(lines.dropFirst(shown.count)) : lines
		if !extends { textView.textStorage?.setAttributedString(NSAttributedString()) }
		for (offset, line) in new.enumerated() {
			let index = (extends ? shown.count : 0) + offset
			textView.textStorage?.append(
				NSAttributedString(
					string: line + "\n",
					attributes: [
						.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
						.foregroundColor: line.contains("opened") || index % 5 == 0
							? highlight : text,
					]))
		}
		shown = lines
		if !new.isEmpty { textView.scrollToEndOfDocument(nil) }
	}

	func riftSetScrollersSuppressed(_ suppressed: Bool) {
		verticalScroller?.alphaValue = suppressed ? 0 : 1
		onSuppressed?(suppressed)
	}
}
