import Foundation
import RiftCore

/// The demo's themes: the built-in ones, then any JSON theme files in a `Themes` folder (next to
/// the executable, or in the demo's source folder).
enum FilesThemes {
	static let all: [RiftTheme] = RiftTheme.builtIn + loaded

	private static let loaded: [RiftTheme] = {
		let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
		let folders = [
			executable.deletingLastPathComponent().appendingPathComponent("Themes"),
			URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
				"Themes"),
		]
		let fm = FileManager.default
		guard
			let folder = folders.first(where: { fm.fileExists(atPath: $0.path) }),
			let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
		else { return [] }
		var seen = Set(RiftTheme.builtIn.map(\.id))
		let themes =
			files
			.filter { $0.pathExtension == "json" }
			.compactMap { try? RiftTheme.load(from: Data(contentsOf: $0)) }
			.joined()
			.filter { seen.insert($0.id).inserted }
		return themes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}()
}
