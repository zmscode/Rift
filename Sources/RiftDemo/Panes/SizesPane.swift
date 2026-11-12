import AppKit
import Quartz
import Rift
import SwiftUI

/// Measures each entry of the tab's folder, biggest first. Busy (closing asks first) while it
/// counts.
struct SizesPane: View {
	let pane: String
	let folder: URL
	@State private var sizes: [(name: String, url: URL, bytes: Int64)] = []
	@State private var isCounting = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(folder.displayName).font(.system(size: 11, weight: .semibold))
				Spacer()
				if isCounting { ProgressView().controlSize(.mini) }
				Text(total.byteText).font(.system(size: 11)).foregroundStyle(.secondary)
			}
			ScrollView {
				VStack(alignment: .leading, spacing: 5) {
					ForEach(sizes.prefix(40), id: \.url) { entry in
						bar(entry.name, entry.bytes)
					}
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.bottom, 10)
		.task(id: folder) { await measure() }
		.onDisappear {
			if Files.shared.measuring.contains(pane) { Files.shared.measuring.remove(pane) }
		}
	}

	private var total: Int64 { sizes.reduce(0) { $0 + $1.bytes } }

	private func bar(_ name: String, _ bytes: Int64) -> some View {
		let largest = max(sizes.first?.bytes ?? 1, 1)
		return VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text(name).lineLimit(1)
				Spacer()
				Text(bytes.byteText).foregroundStyle(.secondary).monospacedDigit()
			}
			.font(.system(size: 10))
			GeometryReader { proxy in
				Capsule().fill(PaneKind.sizes.tint.opacity(0.75))
					.frame(width: max(2, proxy.size.width * CGFloat(bytes) / CGFloat(largest)))
			}
			.frame(height: 4)
		}
	}

	private func measure() async {
		sizes = []
		isCounting = true
		Files.shared.measuring.insert(pane)
		defer {
			isCounting = false
			Files.shared.measuring.remove(pane)
		}
		let entries = await Task.detached { FileItem.contents(of: folder) ?? [] }.value
		if Task.isCancelled { return }
		Files.shared.record("measuring \(folder.displayName)")
		for entry in entries {
			if Task.isCancelled { return }
			let url = entry.url
			let bytes = await Task.detached { Self.allocatedSize(of: url) }.value
			sizes.append((entry.name, url, bytes))
			sizes.sort { $0.bytes > $1.bytes }
		}
		if !Task.isCancelled {
			Files.shared.record("measured \(folder.displayName): \(total.byteText)")
		}
	}

	nonisolated static func allocatedSize(of url: URL) -> Int64 {
		let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
		guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
		guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
		guard
			let enumerator = FileManager.default.enumerator(
				at: url, includingPropertiesForKeys: Array(keys), options: [],
				errorHandler: { _, _ in true })
		else { return 0 }
		var total: Int64 = 0
		var count = 0
		for case let child as URL in enumerator {
			count += 1
			if count % 2000 == 0, Task.isCancelled { break }
			total += Int64((try? child.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
		}
		return total
	}
}

// MARK: - Activity
