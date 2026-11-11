import AppKit
import Quartz
import Rift
import SwiftUI

/// What panes can ask their window to do.
struct PaneCommands: Sendable {
	var openInNewTab: @MainActor @Sendable (URL) -> Void = { _ in }
	var addPane: @MainActor @Sendable (PaneKind) -> Void = { _ in }
}

private struct PaneCommandsKey: EnvironmentKey {
	static let defaultValue = PaneCommands()
}

extension EnvironmentValues {
	var paneCommands: PaneCommands {
		get { self[PaneCommandsKey.self] }
		set { self[PaneCommandsKey.self] = newValue }
	}
}

// MARK: - Pane frame

/// Every pane sits in the same frame: a tinted card with a title row that lines up with the
/// window buttons and moves aside for them.
struct FilesPane: View {
	let pane: RiftPaneContext<String>
	/// The tab the pane is in.
	let tab: Int
	let isTranslucent: Bool
	let activity: RiftStructuralActivity
	/// Draws its own title row (with header bars Rift draws the title).
	var drawsTitle = true

	@Environment(\.riftThemeSelection) private var themeSelection
	@Environment(\.colorScheme) private var colorScheme
	private var kind: PaneKind { PaneIDs.kind(of: pane.paneID) }

	var body: some View {
		VStack(spacing: 0) {
			if drawsTitle {
				HStack(spacing: 6) {
					if kind == .browser { BrowserNavigation(pane: pane.paneID) }
					Spacer(minLength: 0)
					Image(systemName: kind.symbol).foregroundStyle(kind.tint)
					Text(PaneIDs.title(of: pane.paneID)).fontWeight(.semibold)
					if !pane.presentation.isLayoutSettled {
						Text("moving").font(.system(size: 9, weight: .bold)).textCase(.uppercase)
							.padding(.horizontal, 5).padding(.vertical, 1)
							.background(Capsule().fill(kind.tint.opacity(0.35)))
					}
					Spacer(minLength: 0)
					if kind == .browser { BrowserNavigation(pane: pane.paneID).hidden() }
				}
				.font(.system(size: 12))
				.lineLimit(1)
				.frame(height: max(pane.presentation.titleRowHeight ?? 30, 30))
				.padding(.leading, max(pane.presentation.titleLeadingInset, 10))
				.padding(.trailing, max(pane.presentation.titleTrailingInset, 10))
			}
			content.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.foregroundStyle(themeColor(.content))
		.background(themeColor(.surface).opacity(isTranslucent ? 0 : 1))
		.background(
			LinearGradient(
				colors: [
					kind.tint.opacity(isTranslucent ? 0.16 : 0.4),
					kind.tint.opacity(isTranslucent ? 0.03 : 0.2),
				],
				startPoint: .top, endPoint: .bottom))
	}

	private func themeColor(_ role: RiftColorRole) -> Color {
		Color(rift: (themeSelection ?? .standard).theme(isDark: colorScheme == .dark)[role])
	}

	@ViewBuilder private var content: some View {
		switch kind {
		case .browser: BrowserPane(pane: pane.paneID, tab: tab)
		case .preview: PreviewPane(item: Files.shared.selection[tab])
		case .info: InfoPane(item: Files.shared.selection[tab], pane: pane, activity: activity)
		case .sizes:
			if let folder = Files.shared.activeFolder[tab] {
				SizesPane(pane: pane.paneID, folder: folder)
			} else {
				ContentUnavailableView(
					"No Folder", systemImage: PaneKind.sizes.symbol,
					description: Text("Open a browser in this tab."))
			}
		case .activity: ActivityPane()
		}
	}
}

/// The card under the pointer while a pane is dragged.
struct DragCard: View {
	let id: String

	var body: some View {
		let kind = PaneIDs.kind(of: id)
		HStack(spacing: 8) {
			Image(systemName: kind.symbol).font(.system(size: 18)).foregroundStyle(kind.tint)
			VStack(alignment: .leading, spacing: 1) {
				Text(PaneIDs.title(of: id)).font(.system(size: 12, weight: .semibold))
				Text("Edges split · middle swaps · tab bar makes a tab").font(.system(size: 10))
					.foregroundStyle(.secondary)
			}
		}
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
		.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(kind.tint.opacity(0.6)))
	}
}

// MARK: - Browser

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

	var body: some View {
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
