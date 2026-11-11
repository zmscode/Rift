import Rift
import SwiftUI

/// The sidebar: places, the panes in this tab, new panes, and the view options that shape the
/// layout.
struct Navigator: View {
	@Environment(\.riftSidebarTitleRowHeight) private var titleRowHeight
	let tab: FilesTab?
	@Binding var focused: String?
	@Binding var settings: FilesSettings
	let activity: RiftStructuralActivity
	let actions: FilesActions
	/// The tabs as sidebar rows, when they live here.
	let tabList: AnyView?
	@State private var openOptions: Set<String> = ["Look"]

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Color.clear.frame(height: titleRowHeight)
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					if let tabList { tabs(tabList) }
					places("Favourites", Files.favourites)
					places("Locations", Files.locations)
					panes
					addPane
					viewOptions
				}
				.padding(.horizontal, 10)
				.padding(.bottom, 12)
			}
			status
		}
		.toggleStyle(.checkbox)
		.controlSize(.small)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(.ultraThinMaterial)
	}

	// MARK: Sections

	/// The tab rows run edge to edge (they keep their own inset), under a heading with a new-tab
	/// button.
	private func tabs(_ list: AnyView) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text("TABS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
				Spacer()
				Button(action: actions.newTab) { Image(systemName: "plus") }
					.buttonStyle(.plain).foregroundStyle(.secondary).help("New Tab (⌘T)")
			}
			list.padding(.horizontal, -10)
		}
	}

	private var currentFolder: URL? { tab?.browser.map { Files.shared.folder(of: $0) } }

	private func places(_ title: String, _ places: [Files.Place]) -> some View {
		group(title) {
			VStack(spacing: 1) {
				ForEach(places) { place in
					row(
						symbol: place.symbol, tint: .accentColor, title: place.name,
						isSelected: currentFolder == place.url
					) {
						// ⌘-click opens the place in a new tab, as in Finder.
						actions.openPlace(place.url, NSEvent.modifierFlags.contains(.command))
					}
					.contextMenu {
						Button("Open") { actions.openPlace(place.url, false) }
						Button("Open in New Tab") { actions.openPlace(place.url, true) }
					}
				}
			}
		}
	}

	private var panes: some View {
		group("This Tab") {
			VStack(spacing: 1) {
				ForEach((tab?.layout?.paneIDs ?? []) + (tab?.floating.flatMap(\.layout.paneIDs) ?? []), id: \.self) { id in
					let kind = PaneIDs.kind(of: id)
					row(
						symbol: kind.symbol, tint: kind.tint, title: PaneIDs.title(of: id),
						isSelected: focused == id,
						badge: tab?.zoomed == id ? "arrow.up.left.and.arrow.down.right"
							: Files.shared.measuring.contains(id) ? "hourglass"
							: (tab?.floating.contains { $0.layout.contains(id) } ?? false)
								? "macwindow.on.rectangle" : nil
					) { focused = id }
					.contextMenu {
						Button("Focus") { focused = id }
						Button("Close") { actions.closePane(id) }
						Button("Close Others") { actions.closeOthers(id) }
					}
				}
			}
		}
	}

	private var addPane: some View {
		group("Add Beside the Focused Pane") {
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6)], spacing: 6) {
				ForEach(PaneKind.allCases) { kind in
					Button {
						actions.split(.right, kind)
					} label: {
						VStack(spacing: 3) {
							Image(systemName: kind.symbol).font(.system(size: 14))
								.foregroundStyle(kind.tint)
							Text(kind.title).font(.system(size: 10))
						}
						.frame(maxWidth: .infinity, minHeight: 40)
						.background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.help(kind.blurb)
				}
			}
		}
	}

	private var viewOptions: some View {
		group("View Options") {
			option("Theme") {
				Picker("", selection: $settings.themeID) {
					Text("Automatic").tag("auto")
					Divider()
					ForEach(RiftTheme.builtIn) { theme in
						Text("\(theme.name) (\(theme.appearance.rawValue))").tag(theme.id)
					}
				}
				.pickerStyle(.menu)
				.labelsHidden()
				themeStrip
			}
			option("Look") {
				segmented($settings.look, FilesSettings.Look.allCases) { $0.rawValue }
				labelled("Motion") {
					segmented($settings.motion, [.snappy, .natural, .off]) { $0.rawValue.capitalized }
				}
				labelled("New panes") {
					segmented($settings.transition, [.popIn, .edgeGrowth]) {
						$0 == .popIn ? "Pop in" : "Grow"
					}
				}
			}
			option("Focus") {
				labelled("Border") {
					segmented($settings.border, [.glide, .crossfade, .off]) { $0.rawValue.capitalized }
				}
				swatches
				check("Gradient border", $settings.gradientBorder)
				labelled("Unfocused panes lose") {
					segmented($settings.unfocusedFade, [.none, .styling, .text, .both]) {
						switch $0 {
						case .none: "–"
						case .styling: "Surface"
						case .text: "Content"
						case .both: "Both"
						}
					}
				}
			}
			option("Layout") {
				labelled("Content while moving") {
					segmented($settings.contentSizing, [.followsSurface, .pinnedDuringMotion]) {
						$0 == .followsSurface ? "Follow" : "Hold"
					}
				}
				check("Balance on split and close", $settings.autoBalance)
				check("Ask before closing busy panes", $settings.asksBeforeClosingBusyPanes)
				FlowButtons {
					Button("Balance", action: actions.balance)
					Button(tab?.zoomed == nil ? "Zoom" : "Unzoom", action: actions.zoom)
					Button("Close others") { actions.closeOthers(nil) }
				}
			}
			option("Tabs") {
				segmented($settings.tabPlacement, FilesSettings.TabPlacement.allCases) { $0.rawValue }
				labelled("Sidebar text") {
					segmented($settings.sidebarTextSize, RiftSidebarTextSize.allCases) {
						$0.rawValue.capitalized
					}
				}
			}
			option("Sidebar") {
				segmented($settings.sidebarPosition, [.left, .right]) { $0.rawValue.capitalized }
				labelled("Swipe to fold") {
					segmented($settings.swipe, [.swipe, .optionSwipe, .off]) {
						switch $0 {
						case .swipe: "Swipe"
						case .optionSwipe: "⌥ Swipe"
						case .off: "Off"
						}
					}
				}
				check("Keep window width when folding", $settings.keepsWindowWidth)
			}
		}
	}

	private var status: some View {
		let reshaping: [String] = [
			activity.contains(.structuralTransition) ? "motion" : nil,
			activity.contains(.dividerDrag) ? "divider" : nil,
			activity.contains(.paneDrag) ? "drag" : nil,
			activity.contains(.windowLiveResize) ? "resize" : nil,
		].compactMap { $0 }
		return VStack(alignment: .leading, spacing: 2) {
			Text("Moving \(reshaping.isEmpty ? "–" : reshaping.joined(separator: ", "))")
			Text("⌘T tab · ⌘D split · ⌘[ back · ⌥⌘S sidebar").foregroundStyle(.tertiary)
		}
		.font(.system(size: 10, design: .monospaced))
		.foregroundStyle(.secondary)
		.padding(14)
	}

	// MARK: Rows

	private func row(
		symbol: String, tint: Color, title: String, isSelected: Bool, badge: String? = nil,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			HStack(spacing: 8) {
				Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
				Text(title).lineLimit(1)
				Spacer(minLength: 0)
				if let badge { Image(systemName: badge).foregroundStyle(.secondary) }
			}
			.font(.system(size: 12))
			.padding(.horizontal, 8).padding(.vertical, 4)
			.background(
				RoundedRectangle(cornerRadius: 6).fill(isSelected ? tint.opacity(0.25) : .clear))
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	/// One collapsible group of options.
	private func option<Content: View>(_ title: String, @ViewBuilder _ content: @escaping () -> Content)
		-> some View
	{
		DisclosureGroup(
			isExpanded: Binding(
				get: { openOptions.contains(title) },
				set: { if $0 { openOptions.insert(title) } else { openOptions.remove(title) } })
		) {
			VStack(alignment: .leading, spacing: 6) { content() }.padding(.top, 4)
		} label: {
			Text(title).font(.system(size: 12, weight: .medium))
		}
	}

	/// A strip of the current theme's colours.
	private var themeStrip: some View {
		RiftThemeReader { theme in
			HStack(spacing: 2) {
				ForEach(
					[RiftColorRole.canvas, .surfaceRaised, .content, .accent, .danger, .success, .warning,
					 .info], id: \.self
				) { role in
					RoundedRectangle(cornerRadius: 2).fill(Color(rift: theme[role])).frame(height: 10)
				}
			}
		}
	}

	/// The named border colours, as swatches.
	private var swatches: some View {
		let palette = RiftColorPalette(theme: settings.theme)
		return LazyVGrid(columns: [GridItem(.adaptive(minimum: 16, maximum: 16), spacing: 6)], spacing: 6) {
			ForEach(RiftFocusBorderColor.allCases, id: \.self) { name in
				Button {
					settings.borderColor = name
				} label: {
					Circle().fill(Color(nsColor: palette.color(name))).frame(width: 16, height: 16)
						.overlay(
							Circle()
								.strokeBorder(
									.primary.opacity(settings.borderColor == name ? 0.9 : 0), lineWidth: 2)
								.padding(-3))
				}
				.buttonStyle(.plain)
				.help(name.rawValue.capitalized)
			}
		}
		.padding(.vertical, 3)
	}

	// MARK: Helpers

	private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content)
		-> some View
	{
		VStack(alignment: .leading, spacing: 6) {
			Text(title.uppercased()).font(.system(size: 10, weight: .semibold))
				.foregroundStyle(.secondary)
			content()
		}
	}

	private func labelled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content)
		-> some View
	{
		VStack(alignment: .leading, spacing: 3) {
			Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
			content()
		}
	}

	/// A checkbox whose label wraps in a narrow sidebar.
	private func check(_ title: String, _ isOn: Binding<Bool>) -> some View {
		Toggle(isOn: isOn) {
			Text(title).fixedSize(horizontal: false, vertical: true)
		}
	}

	private func segmented<Value: Hashable>(
		_ selection: Binding<Value>, _ values: [Value], label: @escaping (Value) -> String
	) -> some View {
		// Segments when there's room; a pop-up menu in a narrow sidebar.
		ViewThatFits(in: .horizontal) {
			Picker("", selection: selection) {
				ForEach(values, id: \.self) { Text(label($0)).tag($0) }
			}
			.pickerStyle(.segmented)
			.labelsHidden()
			.fixedSize()
			Picker("", selection: selection) {
				ForEach(values, id: \.self) { Text(label($0)).tag($0) }
			}
			.pickerStyle(.menu)
			.labelsHidden()
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

/// Buttons in a row, or stacked when the sidebar is too narrow for the row.
struct FlowButtons<Content: View>: View {
	@ViewBuilder let content: () -> Content

	var body: some View {
		ViewThatFits(in: .horizontal) {
			HStack { content() }.fixedSize()
			VStack(alignment: .leading) { content() }
		}
	}
}
