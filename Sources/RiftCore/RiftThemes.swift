import Foundation

extension RiftTheme {
	/// Builds a theme from hex strings: background, foreground, cursor (accent), selection, and
	/// the 16 terminal colours.
	public static func palette(
		id: String, name: String, appearance: RiftThemeAppearance, background: String,
		foreground: String, cursor: String, selection: String, ansi: [String]
	) -> RiftTheme {
		func c(_ hex: String) -> RiftRGBA { RiftRGBA(hex: hex) ?? RiftRGBA(red: 1, green: 0, blue: 1) }
		return RiftTheme(
			id: id, name: name, appearance: appearance,
			source: RiftThemeSource(
				background: c(background), foreground: c(foreground), cursor: c(cursor),
				selectionBackground: c(selection), ansi: ansi.map(c)))
	}

	// MARK: Dark

	/// Cool graphite with a blue accent.
	public static let graphite = palette(
		id: "graphite", name: "Graphite", appearance: .dark, background: "#16181d",
		foreground: "#c9ced8", cursor: "#6aa8ff", selection: "#273042",
		ansi: [
			"#22252c", "#e5736d", "#7ac47f", "#d9b86a", "#6aa8ff", "#b48ae8", "#5cc3c9", "#aeb4bf",
			"#4a505c", "#f28c86", "#93d897", "#e8ca82", "#8bbcff", "#c6a3f0", "#7bd5da", "#e3e7ee",
		])

	/// Deep sea green with a teal accent.
	public static let harbor = palette(
		id: "harbor", name: "Harbor", appearance: .dark, background: "#0d1a1c",
		foreground: "#bcd3d1", cursor: "#3fd0b4", selection: "#16383a",
		ansi: [
			"#142628", "#e0776f", "#4fc590", "#d6b45f", "#4a9ad6", "#a183d6", "#3fc0c4", "#9fb8b6",
			"#3c5658", "#ee908a", "#6fd8a7", "#e6c77c", "#6cb1e4", "#b79ce2", "#62d3d6", "#dcebea",
		])

	/// Warm charcoal with an ember-orange accent.
	public static let ember = palette(
		id: "ember", name: "Ember", appearance: .dark, background: "#1a1614",
		foreground: "#d8cbc1", cursor: "#f08a4b", selection: "#3a2a22",
		ansi: [
			"#26201d", "#e96a5f", "#a8c46f", "#e5b35a", "#7ea6d8", "#c88bc4", "#7cc1b2", "#bfb2a8",
			"#554a44", "#f4857a", "#bdd68a", "#f0c677", "#99bbe4", "#d9a3d5", "#98d3c6", "#efe5dd",
		])

	/// Near-black violet with an orchid accent.
	public static let nightshade = palette(
		id: "nightshade", name: "Nightshade", appearance: .dark, background: "#15121c",
		foreground: "#cfc8de", cursor: "#c38cff", selection: "#2e2440",
		ansi: [
			"#201b2a", "#ec6f8a", "#7fcf9a", "#e0bd6e", "#7d9cf0", "#c38cff", "#6cc8d8", "#b5adc6",
			"#4b4359", "#f58aa2", "#9ae0b1", "#ecce88", "#98b1f6", "#d4a8ff", "#8ad8e5", "#ebe6f4",
		])

	// MARK: Light

	/// Warm paper with an ink-blue accent.
	public static let paper = palette(
		id: "paper", name: "Paper", appearance: .light, background: "#f7f4ee",
		foreground: "#2c2a26", cursor: "#2f6fd6", selection: "#d8e3f6",
		ansi: [
			"#3a3833", "#c0392b", "#2f8a4c", "#a8730b", "#2f6fd6", "#8a4fbf", "#1f8a8f", "#d9d4ca",
			"#77736a", "#d65244", "#3fa160", "#bd8820", "#4a86e6", "#a068d1", "#2fa1a6", "#f2efe8",
		])

	/// Pale sea-glass with a deep teal accent.
	public static let seaglass = palette(
		id: "seaglass", name: "Sea Glass", appearance: .light, background: "#eef5f3",
		foreground: "#233331", cursor: "#13877a", selection: "#cde8e2",
		ansi: [
			"#2e3f3d", "#c44b4b", "#2b8a5a", "#9c7a16", "#2f6fae", "#7f56b0", "#13877a", "#cfdcd9",
			"#6b7d7a", "#d86060", "#3aa06e", "#b28f28", "#4686c4", "#966cc6", "#24a091", "#f4f9f8",
		])

	/// Soft sand with a terracotta accent.
	public static let dune = palette(
		id: "dune", name: "Dune", appearance: .light, background: "#f6efe6",
		foreground: "#3a2f27", cursor: "#c2552f", selection: "#f0d6c6",
		ansi: [
			"#46392f", "#b8412e", "#5e8a3a", "#b07a1c", "#3e6fa8", "#93507f", "#3d8a85", "#ddd1c3",
			"#85766a", "#cc5640", "#73a04c", "#c48e2e", "#5486bf", "#a96696", "#51a09a", "#fbf6ef",
		])

	/// Cool white with a violet accent.
	public static let frost = palette(
		id: "frost", name: "Frost", appearance: .light, background: "#f3f5f9",
		foreground: "#262a33", cursor: "#6a5ae0", selection: "#dcd9f6",
		ansi: [
			"#30353f", "#c8414f", "#2f8f5b", "#a3790f", "#3366cc", "#6a5ae0", "#1d8aa0", "#d3d7df",
			"#707684", "#dc5763", "#3fa56e", "#b98d22", "#4c7fdc", "#8173ea", "#2fa1b8", "#fafbfd",
		])

	/// Every built-in theme, dark first.
	public static let builtIn: [RiftTheme] = [
		graphite, harbor, ember, nightshade, paper, seaglass, dune, frost,
	]
}

extension RiftThemeSelection {
	/// Graphite in dark mode, Paper in light mode.
	public static let standard = RiftThemeSelection(light: .paper, dark: .graphite)
}
