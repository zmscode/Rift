import AppKit
import Quartz
import Rift
import SwiftUI

/// The selection's details, and this pane's live presentation from Rift.
struct InfoPane: View {
	let item: FileItem?
	let pane: RiftPaneContext<String>
	let activity: RiftStructuralActivity

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				if let item {
					HStack(spacing: 10) {
						Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
							.resizable().frame(width: 40, height: 40)
						VStack(alignment: .leading, spacing: 2) {
							Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
							Text(item.kind).foregroundStyle(.secondary)
						}
					}
					Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
						row("Size", item.size?.byteText ?? "–")
						row(
							"Created",
							item.created?.formatted(date: .abbreviated, time: .shortened) ?? "–")
						row(
							"Modified",
							item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "–")
						row("Where", item.url.deletingLastPathComponent().path)
					}
				} else {
					Text("Select something in a browser.").foregroundStyle(.secondary)
				}
				Divider()
				Text("THIS PANE").font(.system(size: 10, weight: .semibold)).foregroundStyle(
					.secondary)
				layoutState
			}
			.font(.system(size: 11))
			.textSelection(.enabled)
			.padding(.horizontal, 12)
			.padding(.bottom, 12)
			.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private var layoutState: some View {
		let p = pane.presentation
		return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
			row("Focused", pane.isFocused ? "yes" : "no")
			row("Settled", p.isLayoutSettled ? "yes" : "moving")
			GridRow {
				Text("Zoom").foregroundStyle(.secondary)
				ProgressView(value: Double(min(max(p.zoomFraction, 0), 1))).frame(width: 90)
			}
			row("Content", size(p.contentSize))
			row("Target", p.targetSize.map(size) ?? "–")
			row("Cut off", p.hiddenTrailingWidth > 0 ? "\(Int(p.hiddenTrailingWidth))pt" : "–")
			row("Reshaping", activityText)
			row("Hovered", pane.isHovered ? "yes" : "no")
		}
		.font(.system(size: 11, design: .monospaced))
	}

	private func row(_ label: String, _ value: String) -> some View {
		GridRow {
			Text(label).foregroundStyle(.secondary)
			Text(value).lineLimit(3)
		}
	}

	private func size(_ s: CGSize) -> String { "\(Int(s.width))×\(Int(s.height))" }

	private var activityText: String {
		var parts: [String] = []
		if activity.contains(.structuralTransition) { parts.append("motion") }
		if activity.contains(.dividerDrag) { parts.append("divider") }
		if activity.contains(.paneDrag) { parts.append("drag") }
		if activity.contains(.windowLiveResize) { parts.append("resize") }
		return parts.isEmpty ? "–" : parts.joined(separator: ", ")
	}
}

// MARK: - Sizes
