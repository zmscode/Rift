import AppKit
import Quartz
import Rift
import SwiftUI

struct BrowserNavigation: View {
	let pane: String

	var body: some View {
		let files = Files.shared
		HStack(spacing: 2) {
			button("chevron.left", "Back", enabled: files.canGoBack(pane)) { files.goBack(pane) }
			button("chevron.right", "Forward", enabled: files.canGoForward(pane)) {
				files.goForward(pane)
			}
			button(
				"arrow.turn.left.up", "Enclosing Folder",
				enabled: files.folder(of: pane).path != "/"
			) {
				files.goUp(pane)
			}
		}
	}

	private func button(
		_ symbol: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void
	)
		-> some View
	{
		Button(action: action) {
			Image(systemName: symbol).frame(width: 20, height: 20).contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!enabled)
		.opacity(enabled ? 0.85 : 0.3)
		.help(help)
	}
}

/// The browser's view controls, opposite its navigation buttons: icons or list, and icon size.
struct BrowserViewControls: View {
	let pane: String

	var body: some View {
		let files = Files.shared
		let mode = files.viewModes[pane] ?? .icons
		let size = files.iconSizes[pane] ?? .medium
		HStack(spacing: 2) {
			button("minus", "Smaller Icons", enabled: mode == .icons && size != .small) {
				files.iconSizes[pane] = BrowserIconSize(rawValue: size.rawValue - 1)
			}
			button("plus", "Larger Icons", enabled: mode == .icons && size != .large) {
				files.iconSizes[pane] = BrowserIconSize(rawValue: size.rawValue + 1)
			}
			button(
				mode == .icons ? "list.bullet" : "square.grid.2x2",
				mode == .icons ? "Show as List" : "Show as Icons", enabled: true
			) {
				files.viewModes[pane] = mode == .icons ? .list : .icons
			}
		}
	}

	private func button(
		_ symbol: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: symbol).frame(width: 20, height: 20).contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!enabled)
		.opacity(enabled ? 0.85 : 0.3)
		.help(help)
	}
}

/// One file or folder in the icon view: its icon over its name.
struct FileIconCell: View {
	let item: FileItem?
	let url: URL
	let iconSize: CGFloat

	private static let icons = NSCache<NSURL, NSImage>()

	private var icon: NSImage {
		if let cached = Self.icons.object(forKey: url as NSURL) { return cached }
		let image = NSWorkspace.shared.icon(forFile: url.path)
		Self.icons.setObject(image, forKey: url as NSURL)
		return image
	}

	var body: some View {
		VStack(spacing: 4) {
			Image(nsImage: icon).resizable().frame(width: iconSize, height: iconSize)
			Text(item?.name ?? url.lastPathComponent)
				.font(.system(size: 11))
				.multilineTextAlignment(.center)
				.lineLimit(2)
				.frame(maxWidth: .infinity)
		}
		.padding(.horizontal, 4)
		.padding(.top, 6)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
	}
}

/// A folder as a table: name, size, date modified, kind.
struct BrowserPane: View {
	let pane: String
	let tab: Int
	@State private var items: [FileItem] = []
	@State private var unreadable = false
	@State private var selection: Set<URL> = []
	@State private var sortOrder = [
		KeyPathComparator(\FileItem.name, comparator: .localizedStandard)
	]
	@Environment(\.paneCommands) private var commands

	private var folder: URL { Files.shared.folder(of: pane) }

	private var mode: BrowserViewMode { Files.shared.viewModes[pane] ?? .icons }
	private var iconSize: BrowserIconSize { Files.shared.iconSizes[pane] ?? .medium }

	/// The folder's items in the order the user arranged them (new items go last), or sorted.
	private var arranged: [URL] {
		let sorted = sortedItems.map(\.url)
		guard let order = Files.shared.arrangements[folder] else { return sorted }
		let present = Set(sorted)
		let known = Set(order)
		return order.filter(present.contains) + sorted.filter { !known.contains($0) }
	}

	var body: some View {
		Group {
			if mode == .icons { grid } else { table }
		}
		.overlay {
			if unreadable {
				ContentUnavailableView(
					"Can't Read This Folder", systemImage: "lock",
					description: Text("Rift Files may need access in System Settings › Privacy."))
			} else if items.isEmpty {
				Text("Empty folder").foregroundStyle(.tertiary)
			}
		}
		.task(id: folder) { await load() }
		.onChange(of: selection) { _, urls in
			guard let url = urls.first, let item = item(url) else { return }
			Files.shared.selection[tab] = item
			if Files.shared.activeFolder[tab] != folder { Files.shared.activeFolder[tab] = folder }
			Files.shared.record("selected \(item.name)")
		}
		.onAppear {
			if Files.shared.activeFolder[tab] == nil { Files.shared.activeFolder[tab] = folder }
		}
	}

	/// The folder as a grid of icons: drag to rearrange, onto a folder, or into another browser.
	private var grid: some View {
		let folder = folder
		let size = iconSize
		return RiftGrid(
			items: Binding(
				get: { arranged },
				set: { Files.shared.arrangements[folder] = $0 }),
			selection: $selection,
			metrics: RiftGridMetrics(
				itemSize: size.cell, spacing: CGSize(width: 6, height: 6),
				inset: CGSize(width: 10, height: 8)),
			dragGroup: "files",
			label: { $0.lastPathComponent },
			onOpen: { urls in if let url = urls.first { open(url) } },
			canDropOnto: { dragged, target in
				item(target)?.isFolder == true && !dragged.contains(target)
			},
			onDropOnto: { dragged, target in
				// The demo leaves your files alone: it only says what a file manager would do.
				Files.shared.record(
					"would move \(Self.count(dragged)) into \(target.lastPathComponent)")
				return false
			},
			onInsert: { dragged, _ in
				Files.shared.record(
					"would move \(Self.count(dragged)) to \(folder.displayName)")
				return false
			},
			menu: { urls in
				guard let url = arranged.first(where: urls.contains) else { return [] }
				return [
					RiftMenuItem("Open") { open(url) },
					.separator,
					RiftMenuItem("Show in Finder") {
						NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
					},
					RiftMenuItem("Copy Path") {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(url.path, forType: .string)
					},
				]
			}
		) { cell in
			FileIconCell(item: item(cell.id), url: cell.id, iconSize: size.icon)
		}
	}

	private static func count(_ urls: [URL]) -> String {
		urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
	}

	private var table: some View {
		Table(sortedItems, selection: $selection, sortOrder: $sortOrder) {
			TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
				HStack(spacing: 6) {
					Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
						.resizable().frame(width: 16, height: 16)
					Text(item.name).lineLimit(1)
				}
			}
			.width(min: 140, ideal: 240)
			TableColumn("Size") { item in
				Text(item.size?.byteText ?? "--").foregroundStyle(.secondary)
			}
			.width(min: 50, ideal: 70)
			TableColumn("Date Modified") { item in
				Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
					.foregroundStyle(.secondary)
			}
			.width(min: 80, ideal: 140)
			TableColumn("Kind", value: \.kind).width(min: 60, ideal: 100)
		}
		.font(.system(size: 12))
		.scrollContentBackground(.hidden)
		.alternatingRowBackgrounds(.disabled)
		.contextMenu(forSelectionType: URL.self) { urls in
			if let url = urls.first {
				Button("Open") { open(url) }
				if item(url)?.isFolder == true {
					Button("Open in New Tab") { commands.openInNewTab(url) }
				}
				Divider()
				Button("Show in Finder") {
					NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
				}
				Button("Copy Path") {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(url.path, forType: .string)
				}
			}
		} primaryAction: { urls in
			if let url = urls.first { open(url) }
		}
	}

	private var sortedItems: [FileItem] {
		let folders = items.filter(\.isFolder).sorted(using: sortOrder)
		let files = items.filter { !$0.isFolder }.sorted(using: sortOrder)
		return folders + files
	}

	private func item(_ url: URL) -> FileItem? { items.first { $0.url == url } }

	private func load() async {
		let folder = folder
		let loaded = await Task.detached { FileItem.contents(of: folder) }.value
		unreadable = loaded == nil
		items = loaded ?? []
		selection = []
		if Files.shared.activeFolder[tab] != folder { Files.shared.activeFolder[tab] = folder }
	}

	private func open(_ url: URL) {
		if item(url)?.isFolder == true {
			Files.shared.open(url, in: pane)
		} else {
			Files.shared.record("opened \(url.lastPathComponent) in its app")
			NSWorkspace.shared.open(url)
		}
	}
}

// MARK: - Preview
