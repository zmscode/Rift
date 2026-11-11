import AppKit
import Rift
import SwiftUI

// MARK: - Tool kinds

/// The kinds of pane the workbench can open. A pane's ID is "<kind>-<number>".
enum ToolKind: String, CaseIterable, Identifiable {
	case notes, inspector, log, orbit, clock

	var id: String { rawValue }

	var title: String {
		switch self {
		case .notes: "Notes"
		case .inspector: "Inspector"
		case .log: "Log"
		case .orbit: "Orbit"
		case .clock: "Clock"
		}
	}

	var symbol: String {
		switch self {
		case .notes: "note.text"
		case .inspector: "gauge.with.dots.needle.33percent"
		case .log: "text.alignleft"
		case .orbit: "circle.hexagongrid"
		case .clock: "clock"
		}
	}

	var tint: Color {
		switch self {
		case .notes: Color(red: 0.95, green: 0.78, blue: 0.35)
		case .inspector: Color(red: 0.45, green: 0.72, blue: 0.95)
		case .log: Color(red: 0.55, green: 0.85, blue: 0.6)
		case .orbit: Color(red: 0.78, green: 0.55, blue: 0.95)
		case .clock: Color(red: 0.95, green: 0.55, blue: 0.55)
		}
	}

	/// What the pane is for, shown under its title.
	var blurb: String {
		switch self {
		case .notes: "Type to take focus. Unfocused panes fade."
		case .inspector: "This pane's live presentation."
		case .log: "Its scroller hides itself while the layout moves."
		case .orbit: "Pauses while the layout moves."
		case .clock: "Grows with the zoom fraction."
		}
	}
}

/// Hands out pane IDs across every window.
@MainActor
enum PaneIDs {
	private static var counter = 0
	private static var nextKind = 0

	static func make(_ kind: ToolKind) -> String {
		counter += 1
		return "\(kind.rawValue)-\(counter)"
	}

	/// The next kind in turn, for splits that don't name one.
	static func makeNext() -> String {
		let kind = ToolKind.allCases[nextKind % ToolKind.allCases.count]
		nextKind += 1
		return make(kind)
	}

	static func kind(of id: String) -> ToolKind {
		ToolKind(rawValue: String(id.split(separator: "-").first ?? "")) ?? .notes
	}

	static func title(of id: String) -> String {
		"\(kind(of: id).title) \(id.split(separator: "-").last ?? "")"
	}

	static func startingLayout() -> RiftLayout<String> {
		let notes = make(.notes)
		let orbit = make(.orbit)
		let inspector = make(.inspector)
		let log = make(.log)
		nextKind = 4
		return RiftLayout<String>.pane(notes)
			.splitting(notes, with: orbit, edge: .right)!
			.splitting(orbit, with: inspector, edge: .bottom)!
			.splitting(notes, with: log, edge: .bottom)!
	}
}

// MARK: - Pane frame

/// Every tool sits in the same frame: a tinted card with a small centred title.
struct ToolPane: View {
	let pane: RiftPaneContext<String>
	let isTranslucent: Bool
	let activity: RiftStructuralActivity

	private var kind: ToolKind { PaneIDs.kind(of: pane.paneID) }

	var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 6) {
				Image(systemName: kind.symbol).foregroundStyle(kind.tint)
				Text(PaneIDs.title(of: pane.paneID)).fontWeight(.semibold)
				if !pane.presentation.isLayoutSettled {
					Text("moving").font(.system(size: 9, weight: .bold)).textCase(.uppercase)
						.padding(.horizontal, 5).padding(.vertical, 1)
						.background(Capsule().fill(kind.tint.opacity(0.35)))
				}
			}
			.font(.system(size: 12))
			.lineLimit(1)
			// The title row lines up with the window buttons and keeps clear of them (and of a
			// folded sidebar's toggle), centred in the space that is left.
			.frame(height: max(pane.presentation.titleRowHeight ?? 30, 30))
			.frame(maxWidth: .infinity)
			.padding(.leading, pane.presentation.titleLeadingInset)
			.padding(.trailing, pane.presentation.titleTrailingInset)
			Text(kind.blurb).font(.system(size: 10)).foregroundStyle(.secondary)
				.padding(.bottom, 8)
			tool.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.foregroundStyle(themeColor(.content))
		.background(themeColor(.surface).opacity(isTranslucent ? 0 : 1))
		.background(
			LinearGradient(
				colors: [
					kind.tint.opacity(isTranslucent ? 0.22 : 0.55),
					kind.tint.opacity(isTranslucent ? 0.06 : 0.3),
				],
				startPoint: .top, endPoint: .bottom)
		)
	}

	@Environment(\.riftThemeSelection) private var themeSelection
	@Environment(\.colorScheme) private var colorScheme

	private func themeColor(_ role: RiftColorRole) -> Color {
		Color(rift: (themeSelection ?? .standard).theme(isDark: colorScheme == .dark)[role])
	}

	@ViewBuilder private var tool: some View {
		switch kind {
		case .notes: NotesTool(id: pane.paneID)
		case .inspector: InspectorTool(pane: pane, activity: activity)
		case .log: LogTool()
		case .orbit: OrbitTool(isMoving: !pane.presentation.isLayoutSettled, tint: kind.tint)
		case .clock: ClockTool(zoom: pane.presentation.zoomFraction)
		}
	}
}

/// The card shown under the pointer while a pane is dragged.
struct DragCard: View {
	let id: String

	var body: some View {
		let kind = PaneIDs.kind(of: id)
		HStack(spacing: 8) {
			Image(systemName: kind.symbol).font(.system(size: 18)).foregroundStyle(kind.tint)
			VStack(alignment: .leading, spacing: 1) {
				Text(PaneIDs.title(of: id)).font(.system(size: 12, weight: .semibold))
				Text("Drop on an edge to split, the middle to swap").font(.system(size: 10))
					.foregroundStyle(.secondary)
			}
		}
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
		.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(kind.tint.opacity(0.6)))
	}
}

// MARK: - Tools

struct NotesTool: View {
	let id: String
	@State private var text = ""

	var body: some View {
		TextEditor(text: $text)
			.font(.system(size: 13))
			.scrollContentBackground(.hidden)
			.padding(.horizontal, 12)
			.padding(.bottom, 12)
			.overlay(alignment: .topLeading) {
				if text.isEmpty {
					Text("Write something…").foregroundStyle(.tertiary).padding(.leading, 17)
						.allowsHitTesting(false)
				}
			}
	}
}

struct InspectorTool: View {
	let pane: RiftPaneContext<String>
	let activity: RiftStructuralActivity

	var body: some View {
		let p = pane.presentation
		Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
			row("Focused", pane.isFocused ? "yes" : "no")
			row("Settled", p.isLayoutSettled ? "yes" : "no")
			GridRow {
				Text("Zoom").foregroundStyle(.secondary)
				ProgressView(value: Double(min(max(p.zoomFraction, 0), 1))).frame(width: 90)
			}
			row("Content", size(p.contentSize))
			row("Target", p.targetSize.map(size) ?? "–")
			row("Surface", p.surfaceSize.map(size) ?? "–")
			row("Cut off", p.hiddenTrailingWidth > 0 ? "\(Int(p.hiddenTrailingWidth))pt" : "–")
			row("Reshaping", activityText)
		}
		.font(.system(size: 11, design: .monospaced))
		.padding(12)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	private func row(_ label: String, _ value: String) -> some View {
		GridRow {
			Text(label).foregroundStyle(.secondary)
			Text(value)
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

/// A ticking clock whose face grows as the pane zooms.
struct ClockTool: View {
	let zoom: CGFloat

	var body: some View {
		TimelineView(.periodic(from: .now, by: 1)) { context in
			Text(context.date, format: .dateTime.hour().minute().second())
				.font(.system(size: 28 + 40 * zoom, weight: .light, design: .rounded))
				.monospacedDigit()
				.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}
}

/// Rings of dots turning; frozen while the layout moves (so it doesn't redraw every frame).
struct OrbitTool: View {
	let isMoving: Bool
	let tint: Color

	var body: some View {
		TimelineView(.animation(paused: isMoving)) { context in
			Canvas { canvas, size in
				let t = context.date.timeIntervalSinceReferenceDate
				let centre = CGPoint(x: size.width / 2, y: size.height / 2)
				let radius = min(size.width, size.height) / 2 - 12
				for ring in 1...4 {
					let r = radius * CGFloat(ring) / 4
					let count = ring * 6
					for i in 0..<count {
						let angle = Double(i) / Double(count) * 2 * .pi + t * (0.4 / Double(ring))
						let point = CGPoint(
							x: centre.x + r * cos(angle), y: centre.y + r * sin(angle))
						let dot = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
						canvas.fill(
							Path(ellipseIn: dot),
							with: .color(tint.opacity(0.4 + 0.15 * Double(ring))))
					}
				}
			}
		}
		.overlay(alignment: .bottom) {
			if isMoving {
				Text("paused").font(.system(size: 10, weight: .semibold)).foregroundStyle(
					.secondary
				)
				.padding(.bottom, 8)
			}
		}
	}
}

// MARK: - Log

/// A log that keeps growing, in a real `NSScrollView` that hides its own scroller while the layout
/// reshapes (it adopts `RiftScrollerSuppressing`).
struct LogTool: View {
	@State private var model = LogModel()
	@Environment(\.riftThemeSelection) private var themeSelection
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		let theme = (themeSelection ?? .standard).theme(isDark: colorScheme == .dark)
		LogView(
			model: model, text: NSColor(rift: theme[.contentSecondary]),
			highlight: NSColor(rift: theme[.terminalAnsi2]))
			.overlay(alignment: .topTrailing) {
				if model.scrollersHidden {
					Text("scroller hidden").font(.system(size: 9, weight: .bold)).textCase(
						.uppercase
					)
					.padding(.horizontal, 6).padding(.vertical, 2)
					.background(Capsule().fill(.black.opacity(0.25)))
					.padding(8)
				}
			}
			.padding(.horizontal, 6)
			.padding(.bottom, 6)
	}
}

@MainActor
@Observable
final class LogModel {
	var scrollersHidden = false
}

struct LogView: NSViewRepresentable {
	let model: LogModel
	let text: NSColor
	let highlight: NSColor

	func makeNSView(context: Context) -> LogScrollView {
		let view = LogScrollView(model: model)
		view.start()
		return view
	}

	func updateNSView(_ view: LogScrollView, context: Context) {
		view.setColors(text: text, highlight: highlight)
	}

	static func dismantleNSView(_ view: LogScrollView, coordinator: ()) { view.stop() }
}

final class LogScrollView: NSScrollView, RiftScrollerSuppressing {
	private let model: LogModel
	private let textView = NSTextView()
	private var timer: Timer?
	private var line = 0
	private var textColor: NSColor = .secondaryLabelColor
	private var highlightColor: NSColor = .systemGreen

	func setColors(text: NSColor, highlight: NSColor) {
		guard text != textColor || highlight != highlightColor else { return }
		textColor = text
		highlightColor = highlight
		let storage = textView.textStorage
		storage?.addAttribute(
			.foregroundColor, value: text, range: NSRange(location: 0, length: storage?.length ?? 0))
	}
	private static let events = [
		"layout settled", "divider moved", "pane focused", "split right", "zoom toggled",
		"pane swapped", "surface updated", "window resized",
	]

	init(model: LogModel) {
		self.model = model
		super.init(frame: .zero)
		hasVerticalScroller = true
		scrollerStyle = .legacy
		drawsBackground = false
		textView.isEditable = false
		textView.drawsBackground = false
		textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
		textView.textColor = .secondaryLabelColor
		textView.autoresizingMask = [.width]
		documentView = textView
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func start() {
		for _ in 0..<30 { append() }
		timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.append() }
		}
	}

	func stop() {
		timer?.invalidate()
		timer = nil
	}

	private func append() {
		line += 1
		let text = String(format: "%04d  %@\n", line, Self.events[line % Self.events.count])
		textView.textStorage?.append(
			NSAttributedString(
				string: text,
				attributes: [
					.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
					.foregroundColor: line % 4 == 0 ? highlightColor : textColor,
				]))
		textView.scrollToEndOfDocument(nil)
	}

	func riftSetScrollersSuppressed(_ suppressed: Bool) {
		verticalScroller?.alphaValue = suppressed ? 0 : 1
		model.scrollersHidden = suppressed
	}
}
