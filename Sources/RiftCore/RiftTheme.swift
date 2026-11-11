import Foundation

/// An sRGB colour with alpha, 0…1 per channel.
public struct RiftRGBA: Hashable, Sendable, Codable {
	public var red: Double
	public var green: Double
	public var blue: Double
	public var alpha: Double

	public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
		self.red = red
		self.green = green
		self.blue = blue
		self.alpha = alpha
	}

	/// "#rrggbb" or "#rrggbbaa".
	public init?(hex: String) {
		var text = hex.trimmingCharacters(in: .whitespaces)
		if text.hasPrefix("#") { text.removeFirst() }
		guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else {
			return nil
		}
		let hasAlpha = text.count == 8
		let r = (value >> (hasAlpha ? 24 : 16)) & 0xff
		let g = (value >> (hasAlpha ? 16 : 8)) & 0xff
		let b = (value >> (hasAlpha ? 8 : 0)) & 0xff
		let a = hasAlpha ? value & 0xff : 0xff
		self.init(
			red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255,
			alpha: Double(a) / 255)
	}

	public var hex: String {
		func byte(_ v: Double) -> String {
			String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded()))
		}
		return "#" + byte(red) + byte(green) + byte(blue) + (alpha < 1 ? byte(alpha) : "")
	}

	public func withAlpha(_ alpha: Double) -> Self {
		Self(red: red, green: green, blue: blue, alpha: alpha)
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		try container.encode(hex)
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		let text = try container.decode(String.self)
		guard let color = RiftRGBA(hex: text) else {
			throw DecodingError.dataCorruptedError(
				in: container, debugDescription: "Expected #rrggbb or #rrggbbaa, got \(text)")
		}
		self = color
	}
}

// MARK: - OKLab

/// Perceptual colour maths (OKLab and its polar form, OKLCH).
public enum RiftOKLab {
	public struct Lab: Hashable, Sendable {
		public var l: Double, a: Double, b: Double
		public init(l: Double, a: Double, b: Double) {
			self.l = l
			self.a = a
			self.b = b
		}
		public var chroma: Double { (a * a + b * b).squareRoot() }
		public var hue: Double { atan2(b, a) }
	}

	static func linear(_ c: Double) -> Double {
		c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
	}

	static func gamma(_ c: Double) -> Double {
		c <= 0.0031308 ? c * 12.92 : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
	}

	public static func lab(_ color: RiftRGBA) -> Lab {
		let r = linear(color.red)
		let g = linear(color.green)
		let b = linear(color.blue)
		let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
		let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
		let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
		return Lab(
			l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
			a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
			b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
	}

	public static func rgb(_ lab: Lab, alpha: Double = 1) -> RiftRGBA {
		let l = pow(lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b, 3)
		let m = pow(lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b, 3)
		let s = pow(lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b, 3)
		func clamp(_ v: Double) -> Double { min(max(gamma(v), 0), 1) }
		return RiftRGBA(
			red: clamp(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
			green: clamp(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
			blue: clamp(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
			alpha: alpha)
	}

	/// `from` moved `t` of the way to `to`, in OKLab.
	public static func mix(_ from: RiftRGBA, _ to: RiftRGBA, _ t: Double) -> RiftRGBA {
		let a = lab(from)
		let b = lab(to)
		return rgb(
			Lab(l: a.l + (b.l - a.l) * t, a: a.a + (b.a - a.a) * t, b: a.b + (b.b - a.b) * t))
	}

	/// `color` with its OKLCH lightness moved by `delta` and its chroma and hue taken from
	/// `tone` (default: its own).
	public static func shifted(_ color: RiftRGBA, lightness delta: Double, tone: RiftRGBA? = nil)
		-> RiftRGBA
	{
		let base = lab(color)
		let source = tone.map(lab) ?? base
		let c = source.chroma
		let h = source.hue
		return rgb(Lab(l: min(max(base.l + delta, 0), 1), a: c * cos(h), b: c * sin(h)))
	}
}

// MARK: - Themes

public enum RiftThemeAppearance: String, Codable, Sendable, Hashable, CaseIterable {
	case light, dark
}

/// The colours a theme is made from: a terminal-style palette.
public struct RiftThemeSource: Hashable, Sendable, Codable {
	public var background: RiftRGBA
	public var foreground: RiftRGBA
	/// Doubles as the accent colour.
	public var cursor: RiftRGBA
	public var cursorText: RiftRGBA
	public var selectionBackground: RiftRGBA
	public var selectionForeground: RiftRGBA
	/// The 16 terminal colours: black, red, green, yellow, blue, magenta, cyan, white, then the
	/// bright versions.
	public var ansi: [RiftRGBA]

	public init(
		background: RiftRGBA, foreground: RiftRGBA, cursor: RiftRGBA, cursorText: RiftRGBA? = nil,
		selectionBackground: RiftRGBA, selectionForeground: RiftRGBA? = nil, ansi: [RiftRGBA]
	) {
		self.background = background
		self.foreground = foreground
		self.cursor = cursor
		self.cursorText = cursorText ?? background
		self.selectionBackground = selectionBackground
		self.selectionForeground = selectionForeground ?? foreground
		self.ansi = ansi
	}
}

/// Named colours an interface draws with. Every theme provides all of them.
public enum RiftColorRole: String, Codable, Sendable, Hashable, CaseIterable {
	// Surfaces, from the window background up.
	case canvas, surface, surfaceSubtle, surfaceRaised, sidebar
	// Text.
	case content, contentSecondary, contentTertiary
	// Lines.
	case stroke, strokeSubtle, scrollbarHover
	// Controls: translucent overlays of the content colour.
	case control, controlHover, controlPressed, controlOnOverlay
	// Selection.
	case selection, selectionForeground
	// Accent and status colours, each with a solid form, text on it, a tinted container, text
	// on the container, and a border.
	case accent, accentSolid, accentOnSolid, accentContainer, accentOnContainer, accentBorder
	case accentLine, accentDim, accentDimSubtle, accentRingOuter
	case danger, dangerSolid, dangerOnSolid, dangerContainer, dangerOnContainer, dangerBorder
	case success, successSolid, successOnSolid, successContainer, successOnContainer, successBorder
	case warning, warningSolid, warningOnSolid, warningContainer, warningOnContainer, warningBorder
	case info, infoSolid, infoOnSolid, infoContainer, infoOnContainer, infoBorder
	// Terminal.
	case terminalBackground, terminalForeground, terminalCursor, terminalSelection
	case terminalSelectionForeground
	case terminalAnsi0, terminalAnsi1, terminalAnsi2, terminalAnsi3, terminalAnsi4, terminalAnsi5
	case terminalAnsi6, terminalAnsi7, terminalAnsi8, terminalAnsi9, terminalAnsi10
	case terminalAnsi11, terminalAnsi12, terminalAnsi13, terminalAnsi14, terminalAnsi15
}

/// A colour theme: a palette, and every role worked out from it.
public struct RiftTheme: Hashable, Sendable, Identifiable {
	public var id: String
	public var name: String
	public var appearance: RiftThemeAppearance
	public var source: RiftThemeSource
	public private(set) var colors: [RiftColorRole: RiftRGBA]

	/// Builds a theme from its palette. `overrides` replace individual roles.
	public init(
		id: String, name: String, appearance: RiftThemeAppearance, source: RiftThemeSource,
		overrides: [RiftColorRole: RiftRGBA] = [:]
	) {
		self.id = id
		self.name = name
		self.appearance = appearance
		self.source = source
		colors = Self.derive(source, appearance: appearance).merging(overrides) { _, new in new }
	}

	public subscript(role: RiftColorRole) -> RiftRGBA { colors[role] ?? source.foreground }

	/// The roles a palette gives.
	///
	/// - Background, text and the accent come straight from the palette (the accent is the cursor
	///   colour); danger, success, warning and info are terminal red, green, yellow and blue.
	/// - Surfaces, lines and secondary text are the background with its OKLCH lightness moved
	///   toward the foreground's (lighter in a dark theme, darker in a light one): +0.0175 pane,
	///   +0.03 sidebar (darker in a light theme), +0.07 raised, +0.085 overlay controls, +0.136
	///   subtle lines, +0.212 lines, +0.262 scrollbar hover, +0.345 tertiary and +0.444 secondary
	///   text (those two in the foreground's colour).
	/// - Containers are the background mixed toward their colour in OKLab: 16% in a dark theme,
	///   8.5% in a light one.
	/// - Controls are the foreground at 2%, 4.4% (hover) and 8% (pressed); the dimmed accents are the
	///   accent at 11.5%, 5.8% and 16.5%.
	public static func derive(_ s: RiftThemeSource, appearance: RiftThemeAppearance)
		-> [RiftColorRole: RiftRGBA]
	{
		let dark = appearance == .dark
		let sign: Double = dark ? 1 : -1
		let bg = s.background
		let fg = s.foreground
		func lift(_ amount: Double, tone: RiftRGBA? = nil) -> RiftRGBA {
			RiftOKLab.shifted(bg, lightness: sign * amount, tone: tone)
		}
		func ansi(_ i: Int) -> RiftRGBA { i < s.ansi.count ? s.ansi[i] : fg }
		let containerMix = dark ? 0.16 : 0.085
		var c: [RiftColorRole: RiftRGBA] = [:]
		c[.canvas] = bg
		c[.surface] = dark ? lift(0.0175) : RiftOKLab.shifted(bg, lightness: 0.006)
		c[.surfaceSubtle] = dark ? lift(0.025) : RiftOKLab.shifted(bg, lightness: -0.012)
		c[.surfaceRaised] = dark ? lift(0.0695) : RiftOKLab.shifted(bg, lightness: 0.012)
		c[.sidebar] = lift(0.03)
		c[.content] = fg
		c[.contentSecondary] = lift(0.444, tone: fg)
		c[.contentTertiary] = lift(0.345, tone: fg)
		c[.strokeSubtle] = dark ? lift(0.09) : lift(0.03)
		c[.stroke] = dark ? lift(0.136) : lift(0.047)
		c[.scrollbarHover] = lift(0.262)
		c[.control] = fg.withAlpha(dark ? 0.020 : 0.021)
		c[.controlHover] = fg.withAlpha(dark ? 0.042 : 0.046)
		c[.controlPressed] = fg.withAlpha(dark ? 0.075 : 0.089)
		c[.controlOnOverlay] = dark ? lift(0.085) : RiftOKLab.shifted(bg, lightness: -0.004)
		c[.selection] = s.cursor
		c[.selectionForeground] = s.cursorText
		func status(
			_ color: RiftRGBA, _ base: RiftColorRole, _ solid: RiftColorRole,
			_ onSolid: RiftColorRole, _ container: RiftColorRole, _ onContainer: RiftColorRole,
			_ border: RiftColorRole
		) {
			c[base] = color
			c[solid] = color
			c[onSolid] = bg
			c[container] = RiftOKLab.mix(bg, color, containerMix)
			c[onContainer] = color
			c[border] = color
		}
		status(
			s.cursor, .accent, .accentSolid, .accentOnSolid, .accentContainer, .accentOnContainer,
			.accentBorder)
		c[.accentLine] = s.cursor
		c[.accentDim] = s.cursor.withAlpha(dark ? 0.109 : 0.128)
		c[.accentDimSubtle] = s.cursor.withAlpha(dark ? 0.057 : 0.060)
		c[.accentRingOuter] = s.cursor.withAlpha(dark ? 0.152 : 0.189)
		status(
			ansi(1), .danger, .dangerSolid, .dangerOnSolid, .dangerContainer, .dangerOnContainer,
			.dangerBorder)
		status(
			ansi(2), .success, .successSolid, .successOnSolid, .successContainer,
			.successOnContainer, .successBorder)
		status(
			ansi(3), .warning, .warningSolid, .warningOnSolid, .warningContainer,
			.warningOnContainer, .warningBorder)
		status(
			ansi(4), .info, .infoSolid, .infoOnSolid, .infoContainer, .infoOnContainer, .infoBorder)
		c[.terminalBackground] = bg
		c[.terminalForeground] = fg
		c[.terminalCursor] = s.cursor
		c[.terminalSelection] = s.selectionBackground
		c[.terminalSelectionForeground] = s.selectionForeground
		let terminal: [RiftColorRole] = [
			.terminalAnsi0, .terminalAnsi1, .terminalAnsi2, .terminalAnsi3, .terminalAnsi4,
			.terminalAnsi5, .terminalAnsi6, .terminalAnsi7, .terminalAnsi8, .terminalAnsi9,
			.terminalAnsi10, .terminalAnsi11, .terminalAnsi12, .terminalAnsi13, .terminalAnsi14,
			.terminalAnsi15,
		]
		for (i, role) in terminal.enumerated() { c[role] = ansi(i) }
		return c
	}
}

extension RiftTheme: Codable {
	private enum CodingKeys: String, CodingKey { case id, name, appearance, source, overrides }

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let overrides =
			try container.decodeIfPresent([String: RiftRGBA].self, forKey: .overrides) ?? [:]
		self.init(
			id: try container.decode(String.self, forKey: .id),
			name: try container.decode(String.self, forKey: .name),
			appearance: try container.decode(RiftThemeAppearance.self, forKey: .appearance),
			source: try container.decode(RiftThemeSource.self, forKey: .source),
			overrides: Dictionary(
				uniqueKeysWithValues: overrides.compactMap { key, value in
					RiftColorRole(rawValue: key).map { ($0, value) }
				}))
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(name, forKey: .name)
		try container.encode(appearance, forKey: .appearance)
		try container.encode(source, forKey: .source)
		let derived = Self.derive(source, appearance: appearance)
		let overrides = colors.filter { derived[$0.key] != $0.value }
		if !overrides.isEmpty {
			try container.encode(
				Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }),
				forKey: .overrides)
		}
	}

	/// Themes from a JSON array of `{ id, name, appearance, source, overrides? }`.
	public static func load(from data: Data) throws -> [RiftTheme] {
		try JSONDecoder().decode([RiftTheme].self, from: data)
	}
}

/// The theme to use in light mode and the one to use in dark mode.
public struct RiftThemeSelection: Hashable, Sendable {
	public var light: RiftTheme
	public var dark: RiftTheme

	public init(light: RiftTheme, dark: RiftTheme) {
		self.light = light
		self.dark = dark
	}

	/// One theme for both modes.
	public init(_ theme: RiftTheme) { self.init(light: theme, dark: theme) }

	public func theme(isDark: Bool) -> RiftTheme { isDark ? dark : light }
}
