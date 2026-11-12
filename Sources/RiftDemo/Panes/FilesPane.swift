import AppKit
import Quartz
import Rift
import SwiftUI

/// What panes can ask their window to do.
struct PaneCommands: Sendable {
	var openInNewTab: @MainActor @Sendable (URL) -> Void = { _ in }
	var addPane: @MainActor @Sendable (PaneKind) -> Void = { _ in }
}

private struct PaneCommandsKey: EnvironmentKey {
	static let defaultValue = PaneCommands()
}

extension EnvironmentValues {
	var paneCommands: PaneCommands {
		get { self[PaneCommandsKey.self] }
		set { self[PaneCommandsKey.self] = newValue }
	}
}

// MARK: - Pane frame

/// Every pane sits in the same frame: a tinted card with a title row that lines up with the
/// window buttons and moves aside for them.
struct FilesPane: View {
	let pane: RiftPaneContext<String>
	/// The tab the pane is in.
	let tab: Int
	let isTranslucent: Bool
	let activity: RiftStructuralActivity
	/// Draws its own title row (with header bars Rift draws the title).
	var drawsTitle = true

	@Environment(\.riftThemeSelection) private var themeSelection
	@Environment(\.colorScheme) private var colorScheme
	private var kind: PaneKind { PaneIDs.kind(of: pane.paneID) }

	var body: some View {
		VStack(spacing: 0) {
			if drawsTitle {
				HStack(spacing: 6) {
					if kind == .browser { BrowserNavigation(pane: pane.paneID) }
					Spacer(minLength: 0)
					Image(systemName: kind.symbol).foregroundStyle(kind.tint)
					Text(PaneIDs.title(of: pane.paneID)).fontWeight(.semibold)
					if !pane.presentation.isLayoutSettled {
						Text("moving").font(.system(size: 9, weight: .bold)).textCase(.uppercase)
							.padding(.horizontal, 5).padding(.vertical, 1)
							.background(Capsule().fill(kind.tint.opacity(0.35)))
					}
					Spacer(minLength: 0)
					if kind == .browser { BrowserViewControls(pane: pane.paneID) }
				}
				.font(.system(size: 12))
				.lineLimit(1)
				.frame(height: max(pane.presentation.titleRowHeight ?? 30, 30))
				.padding(.leading, max(pane.presentation.titleLeadingInset, 10))
				.padding(.trailing, max(pane.presentation.titleTrailingInset, 10))
			}
			content.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.foregroundStyle(themeColor(.content))
		.background(themeColor(.surface).opacity(isTranslucent ? 0 : 1))
		.background(
			LinearGradient(
				colors: [
					kind.tint.opacity(isTranslucent ? 0.16 : 0.4),
					kind.tint.opacity(isTranslucent ? 0.03 : 0.2),
				],
				startPoint: .top, endPoint: .bottom))
	}

	private func themeColor(_ role: RiftColorRole) -> Color {
		Color(rift: (themeSelection ?? .standard).theme(isDark: colorScheme == .dark)[role])
	}

	@ViewBuilder private var content: some View {
		switch kind {
		case .browser: BrowserPane(pane: pane.paneID, tab: tab)
		case .preview: PreviewPane(item: Files.shared.selection[tab])
		case .info: InfoPane(item: Files.shared.selection[tab], pane: pane, activity: activity)
		case .sizes:
			if let folder = Files.shared.activeFolder[tab] {
				SizesPane(pane: pane.paneID, folder: folder)
			} else {
				ContentUnavailableView(
					"No Folder", systemImage: PaneKind.sizes.symbol,
					description: Text("Open a browser in this tab."))
			}
		case .activity: ActivityPane()
		}
	}
}

/// The card under the pointer while a pane is dragged.
struct DragCard: View {
	let id: String

	var body: some View {
		let kind = PaneIDs.kind(of: id)
		HStack(spacing: 8) {
			Image(systemName: kind.symbol).font(.system(size: 18)).foregroundStyle(kind.tint)
			VStack(alignment: .leading, spacing: 1) {
				Text(PaneIDs.title(of: id)).font(.system(size: 12, weight: .semibold))
				Text("Edges split · middle swaps · tab bar makes a tab").font(.system(size: 10))
					.foregroundStyle(.secondary)
			}
		}
		.padding(10)
		.background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
		.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(kind.tint.opacity(0.6)))
	}
}

// MARK: - Browser
