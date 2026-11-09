import AppKit
import RiftCore
import SwiftUI

/// Sends commands (split, close, focus, …) to the `RiftView` behind a `RiftLayoutView`.
@MainActor
public final class RiftController<PaneID: Hashable & Sendable> {
    public internal(set) weak var view: RiftView<PaneID>?

    public init() {}

    @discardableResult
    public func split(_ pane: PaneID? = nil, edge: RiftEdge, newPane: PaneID) -> Bool {
        view?.split(pane, edge: edge, newPane: newPane) ?? false
    }
    @discardableResult
    public func close(_ pane: PaneID? = nil) -> Bool { view?.close(pane) ?? false }
    @discardableResult
    public func moveFocus(_ direction: RiftDirection) -> Bool { view?.moveFocus(direction) ?? false }
    @discardableResult
    public func resize(toward direction: RiftDirection, by points: CGFloat? = nil) -> Bool {
        view?.resize(toward: direction, by: points) ?? false
    }
    @discardableResult
    public func swap(toward direction: RiftDirection) -> Bool { view?.swap(toward: direction) ?? false }
    public func balance() { view?.balance() }
    public func toggleZoom() { view?.toggleZoom() }
}

/// SwiftUI wrapper around `RiftView`. Each pane's content is a SwiftUI view.
///
/// ```swift
/// @State var layout: RiftLayout<String>? = .pane("a")
/// RiftLayoutView(layout: $layout) { id in Text(id) }
/// ```
public struct RiftLayoutView<PaneID: Hashable & Sendable, Content: View>: NSViewRepresentable {
    @Binding private var layout: RiftLayout<PaneID>?
    @Binding private var focusedPane: PaneID?
    private let configuration: RiftConfiguration
    private let controller: RiftController<PaneID>?
    private let title: ((PaneID) -> String)?
    private let content: (PaneID) -> Content

    public init(
        layout: Binding<RiftLayout<PaneID>?>,
        focusedPane: Binding<PaneID?> = .constant(nil),
        configuration: RiftConfiguration = RiftConfiguration(),
        controller: RiftController<PaneID>? = nil,
        title: ((PaneID) -> String)? = nil,
        @ViewBuilder content: @escaping (PaneID) -> Content
    ) {
        _layout = layout
        _focusedPane = focusedPane
        self.configuration = configuration
        self.controller = controller
        self.title = title
        self.content = content
    }

    public final class Coordinator {
        var parent: RiftLayoutView
        init(_ parent: RiftLayoutView) { self.parent = parent }
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> RiftView<PaneID> {
        let coordinator = context.coordinator
        let view = RiftView<PaneID>(configuration: configuration) { id in
            NSHostingView(rootView: AnyView(coordinator.parent.content(id)))
        }
        view.paneTitle = title
        view.setLayout(layout)
        view.focusedPane = focusedPane ?? layout?.firstPaneID
        view.onLayoutChange = { layout, _ in coordinator.parent.layout = layout }
        view.onFocusChange = { pane in coordinator.parent.focusedPane = pane }
        controller?.view = view
        return view
    }

    public func updateNSView(_ view: RiftView<PaneID>, context: Context) {
        context.coordinator.parent = self
        view.configuration = configuration
        view.paneTitle = title
        controller?.view = view
        // Refresh pane content, including panes that arrived from another view.
        for id in view.paneLayout?.paneIDs ?? [] {
            (view.contentView(for: id) as? NSHostingView<AnyView>)?.rootView = AnyView(content(id))
        }
        if view.paneLayout != layout { view.setLayout(layout, animated: true) }
        if let focusedPane, view.focusedPane != focusedPane { view.focusedPane = focusedPane }
    }
}
