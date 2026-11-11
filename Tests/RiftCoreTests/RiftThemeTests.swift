import Foundation
import Testing

@testable import RiftCore

@Suite struct ThemeTests {
	@Test func hexRoundTrips() {
		let color = RiftRGBA(hex: "#4fe3c1")
		#expect(color?.hex == "#4fe3c1")
		#expect(RiftRGBA(hex: "#00000080")?.alpha ?? 0 > 0.5)
		#expect(RiftRGBA(hex: "nope") == nil)
	}

	@Test func rolesComeFromThePalette() {
		let theme = RiftTheme.graphite
		#expect(theme[.canvas] == theme.source.background)
		#expect(theme[.content] == theme.source.foreground)
		#expect(theme[.accent] == theme.source.cursor)
		#expect(theme[.danger] == theme.source.ansi[1])
		#expect(theme[.info] == theme.source.ansi[4])
		#expect(theme[.accentOnSolid] == theme.source.background)
		#expect(abs(theme[.controlHover].alpha - 0.042) < 1e-9)
	}

	@Test func darkSurfacesAreLighterAndLightOnesDarker() {
		let dark = RiftTheme.graphite
		let light = RiftTheme.paper
		func l(_ c: RiftRGBA) -> Double { RiftOKLab.lab(c).l }
		#expect(l(dark[.surfaceRaised]) > l(dark[.canvas]))
		#expect(abs(l(dark[.surfaceRaised]) - l(dark[.canvas]) - 0.0695) < 0.002)
		#expect(l(light[.sidebar]) < l(light[.canvas]))
		#expect(l(dark[.contentSecondary]) > l(dark[.contentTertiary]))
		#expect(l(light[.contentSecondary]) < l(light[.contentTertiary]))
	}

	@Test func containersMixTowardTheirColour() {
		let theme = RiftTheme.harbor
		let bg = RiftOKLab.lab(theme[.canvas]).l
		let accent = RiftOKLab.lab(theme[.accent]).l
		let container = RiftOKLab.lab(theme[.accentContainer]).l
		#expect(container > bg && container < accent)
	}

	@Test func themesLoadFromJSONWithOverrides() throws {
		let json = """
			[{"id": "x", "name": "X", "appearance": "dark",
			  "source": {"background": "#000000", "foreground": "#ffffff", "cursor": "#ff0000",
			             "cursorText": "#000000", "selectionBackground": "#333333",
			             "selectionForeground": "#ffffff", "ansi": ["#000000", "#ff0000"]},
			  "overrides": {"sidebar": "#123456"}}]
			"""
		let themes = try RiftTheme.load(from: Data(json.utf8))
		#expect(themes.count == 1)
		#expect(themes[0][.sidebar] == RiftRGBA(hex: "#123456"))
		#expect(themes[0][.danger] == RiftRGBA(hex: "#ff0000"))
		let encoded = try JSONEncoder().encode(themes[0])
		let decoded = try JSONDecoder().decode(RiftTheme.self, from: encoded)
		#expect(decoded == themes[0])
	}

	@Test func selectionPicksByAppearance() {
		let selection = RiftThemeSelection.standard
		#expect(selection.theme(isDark: true).id == "graphite")
		#expect(selection.theme(isDark: false).id == "paper")
		#expect(RiftTheme.builtIn.count == 8)
	}

	/// Every theme file the demo ships (or finds locally) decodes, with unique IDs.
	@Test func demoThemeFilesDecode() throws {
		let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
			.deletingLastPathComponent().deletingLastPathComponent()
			.appendingPathComponent("Sources/RiftDemo/Themes")
		let files = try FileManager.default.contentsOfDirectory(
			at: folder, includingPropertiesForKeys: nil
		).filter { $0.pathExtension == "json" }
		#expect(files.contains { $0.lastPathComponent == "0x96f.json" })
		var ids = Set<String>()
		for file in files {
			for theme in try RiftTheme.load(from: Data(contentsOf: file)) {
				#expect(ids.insert(theme.id).inserted, "duplicate \(theme.id)")
				#expect(theme.source.ansi.count == 16)
			}
		}
		#expect(ids.isSuperset(of: ["0x96f", "0x96f-lighter", "0x96f-darker"]))
	}
}
