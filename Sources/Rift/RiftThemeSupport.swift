import AppKit
import RiftCore
import SwiftUI

extension NSColor {
	/// A theme colour.
	public convenience init(rift color: RiftRGBA) {
		self.init(
			srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
	}

	/// A colour that follows the appearance: `selection`'s light theme in light mode, its dark
	/// theme in dark mode.
	public static func rift(_ role: RiftColorRole, in selection: RiftThemeSelection) -> NSColor {
		NSColor(name: nil) { appearance in
			let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
			return NSColor(rift: selection.theme(isDark: dark)[role])
		}
	}
}

extension Color {
	/// A theme colour.
	public init(rift color: RiftRGBA) {
		self.init(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
	}
}

extension RiftColorPalette {
	/// The named border colours from a theme: its accent, its terminal red, blue, green, yellow,
	/// cyan and magenta, and its terminal foreground.
	public init(theme selection: RiftThemeSelection) {
		self.init()
		accent = .rift(.accent, in: selection)
		red = .rift(.terminalAnsi1, in: selection)
		green = .rift(.terminalAnsi2, in: selection)
		yellow = .rift(.terminalAnsi3, in: selection)
		blue = .rift(.terminalAnsi4, in: selection)
		magenta = .rift(.terminalAnsi5, in: selection)
		cyan = .rift(.terminalAnsi6, in: selection)
		foreground = .rift(.terminalForeground, in: selection)
	}
}

/// The neutral grey the built-in surface looks tint with; a theme replaces it with its canvas.
private let riftCanvasGrey: CGFloat = 0.117647

extension NSColor {
	/// This colour with the canvas grey replaced by `canvas` (same alpha), or itself otherwise.
	func rift_replacingCanvas(with canvas: RiftRGBA) -> NSColor {
		guard let srgb = usingColorSpace(.sRGB) else { return self }
		let grey = abs(srgb.redComponent - riftCanvasGrey) < 0.002
			&& abs(srgb.greenComponent - riftCanvasGrey) < 0.002
			&& abs(srgb.blueComponent - riftCanvasGrey) < 0.002
		return grey ? NSColor(rift: canvas.withAlpha(Double(srgb.alphaComponent))) : self
	}
}

extension RiftSurfaceStyle {
	/// This style with its colours taken from `theme`: each colour with a role becomes that role's
	/// colour at its own alpha (as Rex's material styles bind colours to roles), and any other
	/// canvas-grey colour becomes the theme's canvas.
	func rift_themed(_ theme: RiftTheme) -> Self {
		func resolve(_ color: NSColor, _ role: RiftColorRole?) -> NSColor {
			guard let role else { return color.rift_replacingCanvas(with: theme[.canvas]) }
			let alpha = Double(color.usingColorSpace(.sRGB)?.alphaComponent ?? 1)
			return NSColor(rift: theme[role].withAlpha(alpha * theme[role].alpha))
		}
		var style = self
		func themed(_ fill: RiftSurfaceFill) -> RiftSurfaceFill { Self.rift_themedFill(fill, theme) }
		if let glass = style.glass, let tint = glass.tint {
			style.glass?.tint = resolve(tint, glass.tintRole)
		}
		style.backdrop = style.backdrop.map(themed)
		style.fill = style.fill.map(themed)
		style.secondFill = style.secondFill.map(themed)
		style.strokes = style.strokes.map { stroke in
			var stroke = stroke
			stroke.color = resolve(stroke.color, stroke.role)
			return stroke
		}
		style.shadows = style.shadows.map { shadow in
			var shadow = shadow
			shadow.color = resolve(shadow.color, shadow.role)
			return shadow
		}
		return style
	}

	/// A fill in `theme`'s colours (see `rift_themed`).
	static func rift_themedFill(_ fill: RiftSurfaceFill, _ theme: RiftTheme) -> RiftSurfaceFill {
		var fill = fill
		if let role = fill.role {
			let alpha = Double(fill.color.usingColorSpace(.sRGB)?.alphaComponent ?? 1)
			fill.color = NSColor(rift: theme[role].withAlpha(alpha * theme[role].alpha))
		} else {
			fill.color = fill.color.rift_replacingCanvas(with: theme[.canvas])
		}
		return fill
	}
}

extension RiftPaneSurfaces {
	/// These looks with their canvas-grey tints taken from the theme's canvas colour (the light
	/// looks from the light theme, the dark ones from the dark theme).
	public func themed(_ selection: RiftThemeSelection) -> RiftPaneSurfaces {
		func states(_ s: States, _ theme: RiftTheme) -> States {
			States(
				pane: s.pane.rift_themed(theme), focusedPane: s.focusedPane.rift_themed(theme),
				inactiveWindowPane: s.inactiveWindowPane.rift_themed(theme),
				inactiveWindowFocusedPane: s.inactiveWindowFocusedPane.rift_themed(theme))
		}
		return RiftPaneSurfaces(
			light: states(light, selection.light), dark: states(dark, selection.dark))
	}
}

extension RiftWindowSurface {
	/// This surface with its canvas-grey tints taken from the theme's canvas colour.
	public func themed(_ selection: RiftThemeSelection) -> RiftWindowSurface {
		func look(_ l: Look, _ theme: RiftTheme) -> Look {
			var look = l
			if let tint = look.tint {
				if let role = look.tintRole {
					let alpha = Double(tint.usingColorSpace(.sRGB)?.alphaComponent ?? 1)
					look.tint = NSColor(rift: theme[role].withAlpha(alpha * theme[role].alpha))
				} else {
					look.tint = tint.rift_replacingCanvas(with: theme[.canvas])
				}
			}
			if let fill = look.backdrop {
				look.backdrop = RiftSurfaceStyle.rift_themedFill(fill, theme)
			}
			return look
		}
		var surface = self
		surface.light = look(light, selection.light)
		surface.dark = look(dark, selection.dark)
		surface.inactiveWindowLight = look(inactiveWindowLight, selection.light)
		surface.inactiveWindowDark = look(inactiveWindowDark, selection.dark)
		return surface
	}
}

// MARK: - SwiftUI environment

private struct RiftThemeSelectionKey: EnvironmentKey {
	static let defaultValue: RiftThemeSelection? = nil
}

extension EnvironmentValues {
	/// The theme pair Rift views were given (see `RiftConfiguration.theme`).
	public var riftThemeSelection: RiftThemeSelection? {
		get { self[RiftThemeSelectionKey.self] }
		set { self[RiftThemeSelectionKey.self] = newValue }
	}
}

/// Hands its content the theme for the current colour scheme.
public struct RiftThemeReader<Content: View>: View {
	@Environment(\.riftThemeSelection) private var selection
	@Environment(\.colorScheme) private var colorScheme
	private let content: (RiftTheme) -> Content

	/// `content` gets the current theme, or the standard pair's when none was given.
	public init(@ViewBuilder content: @escaping (RiftTheme) -> Content) {
		self.content = content
	}

	public var body: some View {
		content((selection ?? .standard).theme(isDark: colorScheme == .dark))
	}
}
