import RiftCore
import SwiftUI

/// A miniature of a layout: each pane as a tile at its place, floating layers above, and the
/// focused pane highlighted. Click a tile to pick that pane.
public struct RiftPaneMinimap<PaneID: Hashable & Sendable>: View {
	public struct Tile: Identifiable {
		public let id: PaneID
		/// Where the pane sits, as fractions of the layout (0…1).
		public let rect: CGRect
		public let isFloating: Bool
	}

	private let tiles: [Tile]
	private let highlighted: PaneID?
	private let width: CGFloat
	private let aspectRatio: CGFloat
	private let onSelect: ((PaneID) -> Void)?
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	/// - Parameters:
	///   - layout: the tiled panes.
	///   - floating: floating layers, drawn above at their bounds.
	///   - highlighted: the pane to highlight (usually the focused one).
	///   - width: the minimap's width; its height follows `aspectRatio` (width over height).
	public init(
		layout: RiftLayout<PaneID>?, floating: [RiftFloatingLayer<PaneID>] = [],
		highlighted: PaneID? = nil, width: CGFloat = 120, aspectRatio: CGFloat = 16 / 10,
		onSelect: ((PaneID) -> Void)? = nil
	) {
		var tiles = (layout?.unitRects() ?? [:]).map {
			Tile(id: $0.key, rect: $0.value, isFloating: false)
		}
		tiles.sort { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
		for layer in floating where !layer.isMinimised {
			for (id, rect) in layer.layout.unitRects() {
				// A floating layer's panes, placed inside its bounds.
				let b = layer.bounds
				tiles.append(
					Tile(
						id: id,
						rect: CGRect(
							x: b.minX + rect.minX * b.width, y: b.minY + rect.minY * b.height,
							width: rect.width * b.width, height: rect.height * b.height),
						isFloating: true))
			}
		}
		self.tiles = tiles
		self.highlighted = highlighted
		self.width = width
		self.aspectRatio = aspectRatio
		self.onSelect = onSelect
	}

	public var body: some View {
		let size = CGSize(width: width, height: (width / max(aspectRatio, 0.1)).rounded())
		ZStack(alignment: .topLeading) {
			ForEach(tiles) { tile in
				let frame = CGRect(
					x: tile.rect.minX * size.width, y: tile.rect.minY * size.height,
					width: tile.rect.width * size.width, height: tile.rect.height * size.height
				).insetBy(dx: 1, dy: 1)
				let isOn = tile.id == highlighted
				RoundedRectangle(cornerRadius: 3, style: .continuous)
					.fill(
						isOn
							? Color.accentColor.opacity(0.55)
							: Color.primary.opacity(tile.isFloating ? 0.22 : 0.12)
					)
					.overlay(
						RoundedRectangle(cornerRadius: 3, style: .continuous)
							.strokeBorder(
								isOn ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1
							)
					)
					.shadow(color: .black.opacity(tile.isFloating ? 0.25 : 0), radius: 2, y: 1)
					.frame(width: max(frame.width, 2), height: max(frame.height, 2))
					.offset(x: frame.minX, y: frame.minY)
					.contentShape(Rectangle())
					.onTapGesture { onSelect?(tile.id) }
					.accessibilityElement()
					.accessibilityLabel(String(describing: tile.id))
					.accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
			}
		}
		.frame(width: size.width, height: size.height, alignment: .topLeading)
		.animation(reduceMotion ? nil : .snappy(duration: 0.25), value: highlighted)
	}
}

/// A pane navigator: a searchable list of panes in groups (for example tabs), each group with its
/// minimap. Arrow keys move the selection, Return picks it, Escape cancels.
public struct RiftPaneNavigator<PaneID: Hashable & Sendable>: View {
	/// One group of panes (one tab, say).
	public struct Section: Identifiable {
		public var id: AnyHashable
		public var title: String
		public var layout: RiftLayout<PaneID>?
		public var floating: [RiftFloatingLayer<PaneID>]

		public init(
			id: AnyHashable, title: String, layout: RiftLayout<PaneID>?,
			floating: [RiftFloatingLayer<PaneID>] = []
		) {
			self.id = id
			self.title = title
			self.layout = layout
			self.floating = floating
		}

		var panes: [PaneID] { (layout?.paneIDs ?? []) + floating.flatMap(\.layout.paneIDs) }
	}

	private let sections: [Section]
	private let title: (PaneID) -> String
	private let symbol: ((PaneID) -> String)?
	private let current: PaneID?
	private let onPick: (Section.ID, PaneID) -> Void
	private let onCancel: () -> Void
	@State private var query = ""
	@State private var selection: PaneID?
	@FocusState private var searchFocused: Bool

	public init(
		sections: [Section], current: PaneID?, title: @escaping (PaneID) -> String,
		symbol: ((PaneID) -> String)? = nil, onPick: @escaping (Section.ID, PaneID) -> Void,
		onCancel: @escaping () -> Void
	) {
		self.sections = sections
		self.current = current
		self.title = title
		self.symbol = symbol
		self.onPick = onPick
		self.onCancel = onCancel
	}

	private var matches: [(section: Section, panes: [PaneID])] {
		let q = query.trimmingCharacters(in: .whitespaces).lowercased()
		return sections.compactMap { section in
			let panes = section.panes.filter {
				q.isEmpty || title($0).lowercased().contains(q)
					|| section.title.lowercased().contains(q)
			}
			return panes.isEmpty ? nil : (section, panes)
		}
	}

	private var flat: [(Section.ID, PaneID)] {
		matches.flatMap { m in m.panes.map { (m.section.id, $0) } }
	}

	public var body: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
				TextField("Go to pane", text: $query)
					.textFieldStyle(.plain)
					.font(.system(size: 15))
					.focused($searchFocused)
					.onSubmit(pickSelection)
			}
			.padding(12)
			Divider()
			ScrollView {
				VStack(alignment: .leading, spacing: 10) {
					ForEach(matches, id: \.section.id) { match in
						HStack(alignment: .top, spacing: 12) {
							RiftPaneMinimap(
								layout: match.section.layout, floating: match.section.floating,
								highlighted: selection ?? current, width: 72
							) { pane in onPick(match.section.id, pane) }
							VStack(alignment: .leading, spacing: 2) {
								Text(match.section.title).font(.system(size: 11, weight: .semibold))
									.foregroundStyle(.secondary)
								ForEach(match.panes, id: \.self) { pane in
									row(pane, section: match.section.id)
								}
							}
						}
					}
				}
				.padding(12)
			}
			.frame(maxHeight: 360)
		}
		.frame(width: 440)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.onAppear {
			searchFocused = true
			selection = current
		}
		.onKeyPress(.downArrow) {
			step(1)
			return .handled
		}
		.onKeyPress(.upArrow) {
			step(-1)
			return .handled
		}
		.onKeyPress(.escape) {
			onCancel()
			return .handled
		}
		.onChange(of: query) { _, _ in selection = flat.first?.1 }
	}

	private func row(_ pane: PaneID, section: Section.ID) -> some View {
		let isOn = pane == selection
		return Button {
			onPick(section, pane)
		} label: {
			HStack(spacing: 8) {
				if let symbol { Image(systemName: symbol(pane)).frame(width: 16) }
				Text(title(pane)).lineLimit(1)
				Spacer(minLength: 0)
				if pane == current {
					Text("current").font(.system(size: 10)).foregroundStyle(.secondary)
				}
			}
			.font(.system(size: 13))
			.padding(.horizontal, 8).padding(.vertical, 4)
			.background(
				RoundedRectangle(cornerRadius: 6).fill(
					isOn ? Color.accentColor.opacity(0.25) : .clear)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { if $0 { selection = pane } }
	}

	private func step(_ delta: Int) {
		let list = flat
		guard !list.isEmpty else { return }
		let index = list.firstIndex { $0.1 == selection } ?? -1
		selection = list[(index + delta + list.count) % list.count].1
	}

	private func pickSelection() {
		guard let pane = selection ?? flat.first?.1, let entry = flat.first(where: { $0.1 == pane })
		else { return }
		onPick(entry.0, pane)
	}
}
