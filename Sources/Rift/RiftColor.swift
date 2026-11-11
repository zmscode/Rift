import AppKit

extension NSColor {
	/// This colour moved `fraction` of the way to `other`, mixed perceptually (in OKLab), keeping
	/// this colour's alpha blended the same way.
	func rift_mixed(with other: NSColor, by fraction: CGFloat) -> NSColor {
		guard let a = usingColorSpace(.extendedSRGB), let b = other.usingColorSpace(.extendedSRGB)
		else { return self }
		let t = min(max(fraction, 0), 1)
		let la = Self.oklab(a)
		let lb = Self.oklab(b)
		let mixed = (
			la.0 + (lb.0 - la.0) * t, la.1 + (lb.1 - la.1) * t, la.2 + (lb.2 - la.2) * t
		)
		let rgb = Self.srgb(fromOKLab: mixed)
		return NSColor(
			srgbRed: rgb.0, green: rgb.1, blue: rgb.2,
			alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
	}

	/// The focus border gradient for a colour: 10% toward white, the colour, 10% toward black.
	func rift_borderGradient() -> [NSColor] {
		[rift_mixed(with: .white, by: 0.1), self, rift_mixed(with: .black, by: 0.1)]
	}

	private static func linear(_ c: CGFloat) -> CGFloat {
		c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
	}

	private static func gamma(_ c: CGFloat) -> CGFloat {
		c <= 0.0031308 ? c * 12.92 : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055
	}

	private static func oklab(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
		let r = linear(color.redComponent)
		let g = linear(color.greenComponent)
		let b = linear(color.blueComponent)
		let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
		let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
		let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
		return (
			0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
			1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
			0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
		)
	}

	private static func srgb(fromOKLab lab: (CGFloat, CGFloat, CGFloat)) -> (
		CGFloat, CGFloat, CGFloat
	) {
		let l = pow(lab.0 + 0.3963377774 * lab.1 + 0.2158037573 * lab.2, 3)
		let m = pow(lab.0 - 0.1055613458 * lab.1 - 0.0638541728 * lab.2, 3)
		let s = pow(lab.0 - 0.0894841775 * lab.1 - 1.2914855480 * lab.2, 3)
		let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
		let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
		let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
		return (
			min(max(gamma(r), 0), 1), min(max(gamma(g), 0), 1), min(max(gamma(b), 0), 1)
		)
	}
}
