import AppKit
import RiftCore

/// Floating layers: panes lifted out of the tiled layout into window-like cards above it, each
/// with its own split layout. They move (with a little give at the edges, and snapping to them),
/// resize from their edges, come to the front when clicked, minimise to capsules along the
/// bottom, and dock back into the layout.
extension RiftView {
	// MARK: Public API

	/// The floating layers, back to front.
	public var floatingLayers: [RiftFloatingLayer<PaneID>] { floating }

	/// Every pane, tiled and floating.
	public var allPaneIDs: [PaneID] {
		(paneLayout?.paneIDs ?? []) + floating.flatMap(\.layout.paneIDs)
	}

	/// Replaces the floating layers without calling `onFloatingLayersChange`. Panes that are new
	/// get content from `makePaneView`.
	public func setFloatingLayers(_ layers: [RiftFloatingLayer<PaneID>]) {
		guard layers != floating else { return }
		apply(floatingLayers: layers)
	}

	/// Lifts a tiled pane into a new floating layer, sized from its tiled frame (see
	/// `RiftFloatingGeometry.newBounds`).
	@discardableResult
	public func float(_ pane: PaneID? = nil) -> Bool {
		guard let pane = pane ?? focusedPane, paneLayout?.contains(pane) == true else {
			return false
		}
		let area = floatingArea
		let source = frame(of: pane)?.size
		guard let content = detach(pane, reason: .move) else { return false }
		let frame = RiftFloatingGeometry.newBounds(
			for: source, in: area,
			existing: floating.map { RiftFloatingGeometry.absolute($0.bounds, in: area) })
		let layer = RiftFloatingLayer(
			bounds: RiftFloatingGeometry.unit(frame, in: area), layout: .pane(pane))
		var layers = floating
		layers.append(layer)
		apply(floatingLayers: layers, content: [pane: content])
		floatingViews[layer.id]?.alphaValue = 0
		floatingViews[layer.id]?.animator().alphaValue = 1
		focusFloatingPane(pane)
		notifyFloatingChange()
		onFocusChange?(pane)
		return true
	}

	/// Moves a floating pane back into the tiled layout, beside the focused tiled pane.
	@discardableResult
	public func dock(_ pane: PaneID) -> Bool {
		guard let index = floating.firstIndex(where: { $0.layout.contains(pane) }),
			let view = floatingViews[floating[index].id],
			let content = view.content.detach(pane, reason: .transferOut)
		else { return false }
		adopt(pane, content: content, edge: .right, reason: .transferIn)
		return true
	}

	/// Docks every pane of a floating layer.
	public func dockFloatingLayer(_ id: UUID) {
		guard let layer = floating.first(where: { $0.id == id }) else { return }
		for pane in layer.layout.paneIDs { dock(pane) }
	}

	/// Floats the pane if it is tiled, docks it if it floats.
	@discardableResult
	public func toggleFloating(_ pane: PaneID? = nil) -> Bool {
		guard let pane = pane ?? focusedPane else { return false }
		return isFloating(pane) ? dock(pane) : float(pane)
	}

	public func isFloating(_ pane: PaneID) -> Bool {
		floating.contains { $0.layout.contains(pane) }
	}

	/// Hides a floating layer to a capsule along the bottom, or brings it back.
	public func setMinimised(_ minimised: Bool, layer id: UUID) {
		guard let index = floating.firstIndex(where: { $0.id == id }),
			floating[index].isMinimised != minimised
		else { return }
		floating[index].isMinimised = minimised
		if minimised, floatingFocus?.layer == id { returnFocusFromFloating() }
		if !minimised { bringToFront(id) }
		layoutFloating(animated: true)
		notifyFloatingChange()
	}

	/// Brings a floating layer in front of the others.
	public func bringToFront(_ id: UUID) {
		guard let index = floating.firstIndex(where: { $0.id == id }), index != floating.count - 1
		else { return }
		floating.append(floating.remove(at: index))
		keepFloatingInFront()
		notifyFloatingChange()
	}

	// MARK: Internals

	/// Where floating layers live: the view inset by 8pt.
	var floatingArea: CGRect { bounds.insetBy(dx: 8, dy: 8) }

	func floatingContentView(for pane: PaneID) -> NSView? {
		for view in floatingViews.values {
			if let content = view.content.contentView(for: pane) { return content }
		}
		return nil
	}

	private func apply(
		floatingLayers layers: [RiftFloatingLayer<PaneID>], content: [PaneID: NSView] = [:]
	) {
		floating = layers
		let ids = Set(layers.map(\.id))
		for (id, view) in floatingViews where !ids.contains(id) {
			view.removeFromSuperview()
			floatingViews[id] = nil
			if floatingFocus?.layer == id { floatingFocus = nil }
		}
		for layer in layers {
			if let view = floatingViews[layer.id] {
				if view.content.paneLayout != layer.layout {
					view.content.setLayout(layer.layout, animated: true)
				}
				continue
			}
			let view = RiftFloatingLayerView(
				id: layer.id, layout: .pane(layer.layout.firstPaneID), host: self)
			// Panes handed over keep their content; the rest are made fresh.
			for (pane, view2) in content where layer.layout.contains(pane) {
				_ = view.content.detach(pane, reason: .move)
				view.content.adopt(pane, content: view2, reason: .transferIn)
			}
			view.content.setLayout(layer.layout, animated: false)
			wireFloating(view)
			floatingViews[layer.id] = view
			addSubview(view)
		}
		layoutFloating()
		keepFloatingInFront()
	}

	private func wireFloating(_ view: RiftFloatingLayerView<PaneID>) {
		let id = view.id
		view.content.onLayoutChange = { [weak self] layout, _ in
			self?.floatingLayoutChanged(id, layout)
		}
		view.content.onFocusChange = { [weak self] pane in self?.floatingFocusChanged(id, pane) }
		view.content.onTearOut = { [weak self] pane, content, point in
			self?.onTearOut?(pane, content, point)
		}
		view.content.onStructuralActivityChange = { [weak self] _ in self?.forwardFloatingActivity()
		}
		view.content.onHoverChange = { [weak self] pane in self?.floatingHoverChanged(pane) }
	}

	private func floatingLayoutChanged(_ id: UUID, _ layout: RiftLayout<PaneID>?) {
		guard let index = floating.firstIndex(where: { $0.id == id }) else { return }
		if let layout {
			floating[index].layout = layout
		} else {
			// The layer's last pane left: the layer goes with it.
			floating.remove(at: index)
			floatingViews.removeValue(forKey: id)?.removeFromSuperview()
			if floatingFocus?.layer == id { floatingFocus = nil }
			layoutFloating(animated: true)
		}
		notifyFloatingChange()
	}

	private func floatingFocusChanged(_ id: UUID, _ pane: PaneID?) {
		guard let pane else { return }
		if floatingFocus?.pane != pane {
			setFocusAppearanceCleared()
			floatingFocus = (id, pane)
			for (other, view) in floatingViews where other != id { view.content.focusedPane = nil }
			bringToFront(id)
			onFocusChange?(pane)
		}
	}

	/// Focuses a floating pane (and brings its layer forward); `false` if it doesn't float.
	@discardableResult
	func focusFloatingPane(_ pane: PaneID) -> Bool {
		guard let layer = floating.first(where: { $0.layout.contains(pane) }),
			let view = floatingViews[layer.id]
		else { return false }
		if layer.isMinimised { setMinimised(false, layer: layer.id) }
		setFocusAppearanceCleared()
		floatingFocus = (layer.id, pane)
		for (other, other2) in floatingViews where other != layer.id {
			other2.content.focusedPane = nil
		}
		view.content.focusedPane = pane
		bringToFront(layer.id)
		return true
	}

	func clearFloatingFocus() {
		floatingFocus = nil
		for view in floatingViews.values { view.content.focusedPane = nil }
	}

	/// Tiled panes stop drawing focus while a floating pane has it.
	private func setFocusAppearanceCleared() {
		if let tiled = tiledFocus { tiledFocusBeforeFloating = tiled }
		setFocus(nil, notify: false, makeFirstResponder: false)
	}

	/// Focus goes back to the tiled pane that had it (or the first one), and is reported.
	func returnFocusFromFloating() {
		clearFloatingFocus()
		let target =
			tiledFocusBeforeFloating.flatMap { paneLayout?.contains($0) == true ? $0 : nil }
			?? paneLayout?.firstPaneID
		setFocus(target, notify: false, makeFirstResponder: true)
		onFocusChange?(target)
	}

	/// Hover inside floating layers is reported with the tiled panes'.
	private func floatingHoverChanged(_ pane: PaneID?) {
		onHoverChange?(pane ?? hoveredPane)
	}

	private func forwardFloatingActivity() {
		var activity = structuralActivity
		for view in floatingViews.values { activity.formUnion(view.content.structuralActivity) }
		onStructuralActivityChange?(activity)
	}

	func notifyFloatingChange() { onFloatingLayersChange?(floating) }

	func keepFloatingInFront() {
		for layer in floating {
			guard let view = floatingViews[layer.id], view.superview === self else { continue }
			view.removeFromSuperview()
			super.addSubview(view, positioned: .above, relativeTo: nil)
		}
		for capsule in floatingCapsules.values where capsule.superview === self {
			capsule.removeFromSuperview()
			super.addSubview(capsule, positioned: .above, relativeTo: nil)
		}
	}

	func floatingHitTest(_ point: NSPoint) -> NSView? {
		let local = convert(point, from: superview)
		for capsule in floatingCapsules.values
		where !capsule.isHidden && capsule.frame.contains(local) {
			return capsule.hitTest(local)
		}
		for layer in floating.reversed() where !layer.isMinimised {
			guard let view = floatingViews[layer.id] else { continue }
			// Resize handles reach a few points outside the card.
			if view.frame.insetBy(
				dx: -RiftFloatingMetrics.edgeThickness / 2,
				dy: -RiftFloatingMetrics.edgeThickness / 2
			).contains(local),
				let hit = view.hitTest(local)
			{
				return hit
			}
		}
		return nil
	}

	/// Places the layers from their unit bounds, and the capsules of minimised ones.
	func layoutFloating(animated: Bool = false) {
		let area = floatingArea
		for layer in floating {
			guard let view = floatingViews[layer.id] else { continue }
			view.cornerRadius = configuration.windowSurface?.cornerRadius ?? 12
			view.isHidden = layer.isMinimised
			if floatingInteraction?.layer == layer.id { continue }
			let frame = RiftFloatingGeometry.absolute(layer.bounds, in: area)
			if animated, window != nil {
				NSAnimationContext.runAnimationGroup { context in
					context.duration = 0.25
					context.allowsImplicitAnimation = true
					view.animator().frame = frame
				}
			} else {
				view.frame = frame
			}
		}
		let minimised = floating.filter(\.isMinimised)
		for (id, capsule) in floatingCapsules where !minimised.contains(where: { $0.id == id }) {
			capsule.removeFromSuperview()
			floatingCapsules[id] = nil
		}
		var widths: [CGFloat] = []
		var capsules: [RiftFloatingCapsule] = []
		for layer in minimised {
			let capsule = floatingCapsules[layer.id] ?? makeCapsule(layer.id)
			let names = layer.layout.paneIDs.map { paneTitle?($0) ?? String(describing: $0) }
			capsule.title =
				names.count > 1 ? "\(names[0]) +\(names.count - 1)" : (names.first ?? "")
			widths.append(capsule.intrinsicContentSize.width + 24)
			capsules.append(capsule)
		}
		for (capsule, frame) in zip(
			capsules, RiftFloatingGeometry.capsuleFrames(widths: widths, in: area))
		{
			capsule.frame = frame
		}
	}

	private func makeCapsule(_ id: UUID) -> RiftFloatingCapsule {
		let capsule = RiftFloatingCapsule(layerID: id)
		capsule.onPress = { [weak self] in self?.setMinimised(false, layer: id) }
		capsule.toolTip = "Show"
		floatingCapsules[id] = capsule
		addSubview(capsule)
		return capsule
	}

	// MARK: Move and resize

	func floatingMove(
		_ view: RiftFloatingLayerView<PaneID>?, phase: RiftFloatingDragPhase, delta: CGSize
	) {
		guard let view else { return }
		switch phase {
		case .began:
			focusLayer(view)
			floatingInteraction = (view.id, view.frame, nil)
			view.setActive(true, animated: true)
		case .changed:
			guard let interaction = floatingInteraction, interaction.layer == view.id else {
				return
			}
			view.frame = RiftFloatingGeometry.moved(interaction.start, by: delta, in: floatingArea)
		case .ended:
			endFloatingInteraction(view)
		}
	}

	func floatingResize(
		_ view: RiftFloatingLayerView<PaneID>?, edges: RiftResizeEdges,
		phase: RiftFloatingDragPhase,
		delta: CGSize
	) {
		guard let view else { return }
		switch phase {
		case .began:
			focusLayer(view)
			floatingInteraction = (view.id, view.frame, edges)
			view.setActive(true, animated: true)
		case .changed:
			guard let interaction = floatingInteraction, interaction.layer == view.id else {
				return
			}
			view.frame = RiftFloatingGeometry.resized(
				interaction.start, edges: edges, by: delta, in: floatingArea)
		case .ended:
			endFloatingInteraction(view)
		}
	}

	/// Pressing a layer's strip or edges focuses its pane (the one it last focused) and brings
	/// it forward.
	private func focusLayer(_ view: RiftFloatingLayerView<PaneID>) {
		guard let pane = view.content.focusedPane ?? view.content.paneLayout?.firstPaneID else {
			return bringToFront(view.id)
		}
		let changed = floatingFocus?.pane != pane
		focusFloatingPane(pane)
		if changed { onFocusChange?(pane) }
	}

	private func endFloatingInteraction(_ view: RiftFloatingLayerView<PaneID>) {
		floatingInteraction = nil
		view.setActive(false, animated: true)
		// Anything pulled past an edge settles back inside.
		let area = floatingArea
		var frame = view.frame
		frame.size.width = min(frame.width, area.width)
		frame.size.height = min(frame.height, area.height)
		frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
		frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
		if frame != view.frame {
			NSAnimationContext.runAnimationGroup { context in
				context.duration = 0.25
				context.allowsImplicitAnimation = true
				view.animator().frame = frame
			}
		}
		if let index = floating.firstIndex(where: { $0.id == view.id }) {
			floating[index].bounds = RiftFloatingGeometry.unit(frame, in: area)
			notifyFloatingChange()
		}
	}
}
