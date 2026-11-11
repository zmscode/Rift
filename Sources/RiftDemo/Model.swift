import AppKit
import Rift
import SwiftUI

// MARK: - Pane kinds

/// The kinds of pane Rift Files can open. A pane's ID is "<kind>-<number>".
enum PaneKind: String, CaseIterable, Identifiable {
	case browser, preview, info, sizes, activity

	var id: String { rawValue }

	var title: String {
		switch self {
		case .browser: "Browser"
		case .preview: "Preview"
		case .info: "Info"
		case .sizes: "Sizes"
		case .activity: "Activity"
		}
	}

	var symbol: String {
		switch self {
		case .browser: "folder"
		case .preview: "eye"
		case .info: "info.circle"
		case .sizes: "chart.bar.xaxis"
		case .activity: "list.bullet.rectangle"
		}
	}

	var tint: Color {
		switch self {
		case .browser: Color(red: 0.42, green: 0.66, blue: 0.98)
		case .preview: Color(red: 0.95, green: 0.74, blue: 0.36)
		case .info: Color(red: 0.55, green: 0.82, blue: 0.62)
		case .sizes: Color(red: 0.78, green: 0.56, blue: 0.95)
		case .activity: Color(red: 0.93, green: 0.55, blue: 0.52)
		}
	}

	/// What the pane is for (shown on its drag card and in empty states).
	var blurb: String {
		switch self {
		case .browser: "Lists a folder. Double-click to open."
		case .preview: "Quick Look of the tab's selection."
		case .info: "The selection's details and this pane's live layout state."
		case .sizes: "Measures the folder's contents. Busy while it counts."
		case .activity: "Everything that happens. Its scroller hides while panes move."
		}
	}
}

/// Hands out pane IDs across every window.
@MainActor
enum PaneIDs {
	private static var counter = 0

	static func make(_ kind: PaneKind) -> String {
		counter += 1
		return "\(kind.rawValue)-\(counter)"
	}

	static func kind(of id: String) -> PaneKind {
		PaneKind(rawValue: String(id.split(separator: "-").first ?? "")) ?? .browser
	}

	/// A browser is named after its folder; other panes after their kind.
	/// A pane's name: what it was renamed to, a browser's folder, or its kind.
	static func title(of id: String) -> String {
		if let custom = Files.shared.paneNames[id] { return custom }
		return kind(of: id) == .browser
			? Files.shared.folder(of: id).displayName : kind(of: id).title
	}

	/// A browser on `folder` with a preview and info beside it, and the activity log under it.
	static func startingLayout(at folder: URL = Files.home) -> RiftLayout<String> {
		let browser = make(.browser)
		let preview = make(.preview)
		let info = make(.info)
		let activity = make(.activity)
		Files.shared.setFolder(folder, of: browser)
		return RiftLayout<String>.pane(browser)
			.splitting(browser, with: preview, edge: .right)!
			.splitting(preview, with: info, edge: .bottom)!
			.splitting(browser, with: activity, edge: .bottom)!
	}

	/// A browser on `folder` with its sizes beside it.
	static func measuringLayout(at folder: URL) -> RiftLayout<String> {
		let browser = make(.browser)
		let sizes = make(.sizes)
		Files.shared.setFolder(folder, of: browser)
		return RiftLayout<String>.pane(browser).splitting(browser, with: sizes, edge: .right)!
	}

	/// A lone browser on `folder`.
	static func browser(at folder: URL) -> RiftLayout<String> {
		let browser = make(.browser)
		Files.shared.setFolder(folder, of: browser)
		return .pane(browser)
	}
}

// MARK: - Files

/// One entry in a folder.
struct FileItem: Identifiable, Hashable, Sendable {
	let url: URL
	var id: URL { url }
	let name: String
	let isFolder: Bool
	let size: Int64?
	let created: Date?
	let modified: Date?
	let kind: String

	static let keys: [URLResourceKey] = [
		.isDirectoryKey, .isPackageKey, .fileSizeKey, .creationDateKey,
		.contentModificationDateKey, .localizedTypeDescriptionKey, .localizedNameKey,
	]

	nonisolated static func load(_ url: URL) -> FileItem {
		let values = try? url.resourceValues(forKeys: Set(keys))
		let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
		return FileItem(
			url: url, name: values?.localizedName ?? url.lastPathComponent, isFolder: isFolder,
			size: isFolder ? nil : values?.fileSize.map(Int64.init),
			created: values?.creationDate, modified: values?.contentModificationDate,
			kind: values?.localizedTypeDescription ?? (isFolder ? "Folder" : "Document"))
	}

	/// A folder's visible entries, folders first, in Finder's name order.
	nonisolated static func contents(of folder: URL) -> [FileItem]? {
		guard
			let urls = try? FileManager.default.contentsOfDirectory(
				at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
		else { return nil }
		return urls.map(load).sorted {
			$0.isFolder != $1.isFolder
				? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending
		}
	}
}

extension URL {
	/// The name Finder shows ("Macintosh HD" for the root).
	var displayName: String {
		path == "/"
			? (try? resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "/"
			: FileManager.default.displayName(atPath: path)
	}
}

/// Where the panes of every window keep their state, so a pane keeps its folder when it moves to
/// another tab or window.
@MainActor
@Observable
final class Files {
	static let shared = Files()
	nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser

	struct Place: Identifiable {
		let name: String
		let symbol: String
		let url: URL
		var id: URL { url }
	}

	static let favourites: [Place] = {
		let fm = FileManager.default
		func dir(_ d: FileManager.SearchPathDirectory) -> URL {
			fm.urls(for: d, in: .userDomainMask).first ?? home
		}
		return [
			Place(name: home.lastPathComponent, symbol: "house", url: home),
			Place(name: "Desktop", symbol: "menubar.dock.rectangle", url: dir(.desktopDirectory)),
			Place(name: "Documents", symbol: "doc", url: dir(.documentDirectory)),
			Place(name: "Downloads", symbol: "arrow.down.circle", url: dir(.downloadsDirectory)),
			Place(
				name: "Applications", symbol: "square.grid.3x3",
				url: URL(fileURLWithPath: "/Applications")),
		]
	}()

	static let locations: [Place] = [
		Place(
			name: URL(fileURLWithPath: "/").displayName, symbol: "internaldrive",
			url: URL(fileURLWithPath: "/"))
	]

	private struct History {
		var back: [URL] = []
		var forward: [URL] = []
	}

	// Seeding a new pane's folder happens while windows are being built, so it mustn't notify
	// observers (that would rebuild the window that is seeding it). Navigation bumps `revision`.
	@ObservationIgnored private var folders: [String: URL] = [:]
	@ObservationIgnored private var histories: [String: History] = [:]
	private var revision = 0
	/// Each tab's selected item and the folder it was picked in.
	var selection: [Int: FileItem] = [:]
	var activeFolder: [Int: URL] = [:]
	/// Sizes panes still counting.
	var measuring: Set<String> = []
	private(set) var log: [String] = []
	/// Names panes were given by renaming their header title.
	var paneNames: [String: String] = [:]

	func folder(of pane: String) -> URL {
		_ = revision
		return folders[pane] ?? Self.home
	}

	func setFolder(_ url: URL, of pane: String) { folders[pane] = url }

	func open(_ url: URL, in pane: String) {
		let current = folder(of: pane)
		guard url != current else { return }
		histories[pane, default: History()].back.append(current)
		histories[pane]?.forward.removeAll()
		folders[pane] = url
		revision += 1
		record("opened \(url.displayName)")
	}

	func canGoBack(_ pane: String) -> Bool {
		_ = revision
		return !(histories[pane]?.back.isEmpty ?? true)
	}

	func canGoForward(_ pane: String) -> Bool {
		_ = revision
		return !(histories[pane]?.forward.isEmpty ?? true)
	}

	func goBack(_ pane: String) {
		guard let url = histories[pane]?.back.popLast() else { return }
		histories[pane]?.forward.append(folder(of: pane))
		folders[pane] = url
		revision += 1
		record("back to \(url.displayName)")
	}

	func goForward(_ pane: String) {
		guard let url = histories[pane]?.forward.popLast() else { return }
		histories[pane]?.back.append(folder(of: pane))
		folders[pane] = url
		revision += 1
		record("forward to \(url.displayName)")
	}

	func goUp(_ pane: String) {
		let current = folder(of: pane)
		guard current.path != "/" else { return }
		open(current.deletingLastPathComponent(), in: pane)
	}

	func record(_ event: String) {
		let time = Date.now.formatted(date: .omitted, time: .standard)
		log.append("\(time)  \(event)")
		if log.count > 500 { log.removeFirst(log.count - 500) }
	}
}

extension Int64 {
	var byteText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
