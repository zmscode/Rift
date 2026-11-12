import AppKit
import Quartz
import Rift
import SwiftUI

struct PreviewPane: View {
	let item: FileItem?

	var body: some View {
		if let item {
			QuickLookView(url: item.url).padding(.horizontal, 8).padding(.bottom, 8)
		} else {
			ContentUnavailableView(
				"Nothing Selected", systemImage: "eye",
				description: Text("Pick a file in a browser in this tab."))
		}
	}
}

struct QuickLookView: NSViewRepresentable {
	let url: URL

	func makeNSView(context: Context) -> QLPreviewView {
		let view = QLPreviewView(frame: .zero, style: .compact)!
		view.autostarts = true
		view.shouldCloseWithWindow = false
		return view
	}

	func updateNSView(_ view: QLPreviewView, context: Context) {
		if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
	}

	static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

// MARK: - Info
