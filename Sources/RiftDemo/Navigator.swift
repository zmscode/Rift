import Rift
import SwiftUI

/// The workbench's sidebar: the open panes, new tools, and the settings that shape the layout.
struct Navigator: View {
	let layout: RiftLayout<String>?
	@Binding var focused: String?
	let zoomed: String?
	@Binding var settings: WorkbenchSettings
	let activity: RiftStructuralActivity
	let foldProgress: CGFloat
	let actions: WorkbenchActions

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Workbench").font(.system(size: 15, weight: .bold))
				.padding(.horizontal, 14).padding(.top, 50).padding(.bottom, 8)
			ScrollView {
				VStack(alignment: .leading, spacing: 14) {
					openPanes
					newTools
					group("Look") {
						segmented($settings.look, WorkbenchSettings.Look.allCases) { $0.rawValue }
						labelled("Motion") {
							segmented($settings.motion, [.snappy, .natural, .off]) {
								$0.rawValue.capitalized
							}
						}
						labelled("New panes") {
							segmented($settings.transition, [.popIn, .edgeGrowth]) {
								$0 == .popIn ? "Pop in" : "Grow"
							}
						}
					}
					group("Focus") {
						labelled("Border") {
							segmented($settings.border, [.glide, .crossfade, .off]) {
								$0.rawValue.capitalized
							}
						}
						swatches
						Toggle("Gradient border", isOn: $settings.gradientBorder)
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
					group("Layout") {
						labelled("Content while moving") {
							segmented(
								$settings.contentSizing, [.followsSurface, .pinnedDuringMotion]
							) {
								$0 == .followsSurface ? "Follow" : "Hold"
							}
						}
						Toggle("Balance on split and close", isOn: $settings.autoBalance)
						Toggle("Ask before closing busy panes", isOn: $settings.asksBeforeClosingBusyPanes)
						HStack {
							Button("Balance", action: actions.balance)
							Button(zoomed == nil ? "Zoom" : "Unzoom", action: actions.zoom)
							Button("Close others") { actions.closeOthers(nil) }
						}
					}
					group("Sidebar") {
						segmented($settings.sidebarPosition, [.left, .right]) {
							$0.rawValue.capitalized
						}
						labelled("Swipe to fold") {
							segmented($settings.swipe, [.swipe, .optionSwipe, .off]) {
								switch $0 {
								case .swipe: "Swipe"
								case .optionSwipe: "⌥ Swipe"
								case .off: "Off"
								}
							}
						}
						Toggle("Keep window width when folding", isOn: $settings.keepsWindowWidth)
					}
				}
				.padding(.horizontal, 14)
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

	private var openPanes: some View {
		group("Open") {
			VStack(spacing: 1) {
				ForEach(layout?.paneIDs ?? [], id: \.self) { id in
					let kind = PaneIDs.kind(of: id)
					Button {
						focused = id
					} label: {
						HStack(spacing: 8) {
							Image(systemName: kind.symbol).foregroundStyle(kind.tint).frame(
								width: 16)
							Text(PaneIDs.title(of: id))
							Spacer()
							if zoomed == id {
								Image(systemName: "arrow.up.left.and.arrow.down.right")
							}
						}
						.padding(.horizontal, 8).padding(.vertical, 5)
						.background(
							RoundedRectangle(cornerRadius: 6)
								.fill(focused == id ? kind.tint.opacity(0.3) : .clear)
						)
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
					.contextMenu {
						Button("Focus") { focused = id }
						Button("Close") { actions.closePane(id) }
						Button("Close Others") { actions.closeOthers(id) }
					}
				}
			}
		}
	}

	/// The named border colours, as swatches.
	private var swatches: some View {
		let palette = RiftColorPalette()
		return HStack(spacing: 6) {
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

	private var newTools: some View {
		group("New beside the focused pane") {
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
				ForEach(ToolKind.allCases) { kind in
					Button {
						actions.split(.right, kind)
					} label: {
						VStack(spacing: 3) {
							Image(systemName: kind.symbol).font(.system(size: 15))
								.foregroundStyle(kind.tint)
							Text(kind.title).font(.system(size: 10))
						}
						.frame(maxWidth: .infinity, minHeight: 44)
						.background(
							RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
						)
						.contentShape(Rectangle())
					}
					.buttonStyle(.plain)
				}
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
			Text("Focus  \(focused.map(PaneIDs.title(of:)) ?? "–")")
			Text("Moving \(reshaping.isEmpty ? "–" : reshaping.joined(separator: ", "))")
			Text("⌘D split · ⌥⌘S sidebar · ⇧⌘↩ zoom")
				.foregroundStyle(.tertiary)
		}
		.font(.system(size: 10, design: .monospaced))
		.foregroundStyle(.secondary)
		.padding(14)
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

	private func segmented<Value: Hashable>(
		_ selection: Binding<Value>, _ values: [Value], label: @escaping (Value) -> String
	) -> some View {
		Picker("", selection: selection) {
			ForEach(values, id: \.self) { Text(label($0)).tag($0) }
		}
		.pickerStyle(.segmented)
		.labelsHidden()
	}
}
