import AppKit
import RiftCore

/// A plain flipped view.
class RiftFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Hosts one pane: an optional header, the content, and the focus border.
final class RiftPaneContainerView: RiftFlippedView {
    let header = RiftPaneHeaderView()
    let contentClip = RiftFlippedView()
    let border = RiftFocusBorderView()
    private(set) var contentView: NSView

    var headerHeight: CGFloat = 24 { didSet { layoutParts() } }
    var showsHeader = true { didSet { header.isHidden = !showsHeader; layoutParts() } }
    var cornerRadius: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = cornerRadius > 0
            border.cornerRadius = cornerRadius
        }
    }
    var inactiveAlpha: CGFloat = 1 { didSet { updateFocusAppearance() } }
    var isFocused = false { didSet { updateFocusAppearance() } }

    init(content: NSView) {
        contentView = content
        super.init(frame: .zero)
        wantsLayer = true
        autoresizesSubviews = true
        header.autoresizingMask = [.width]
        contentClip.autoresizingMask = [.width, .height]
        border.autoresizingMask = [.width, .height]
        addSubview(contentClip)
        addSubview(header)
        addSubview(border)
        install(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func install(_ content: NSView) {
        content.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = contentClip.bounds
        contentClip.addSubview(content)
    }

    /// Removes the content so it can be adopted by another container.
    func detachContent() -> NSView {
        contentView.removeFromSuperview()
        return contentView
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutParts()
    }

    private func layoutParts() {
        let h = showsHeader ? min(headerHeight, bounds.height) : 0
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        contentClip.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        border.frame = bounds
    }

    private func updateFocusAppearance() {
        border.isFocused = isFocused
        header.isFocused = isFocused
        contentClip.alphaValue = isFocused ? 1 : inactiveAlpha
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { header.title }
}

/// A small grip that starts a pane drag when the header itself moves the window.
final class RiftHeaderGripView: NSImageView {
    var onMouseDown: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Move Pane")
        symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        contentTintColor = .tertiaryLabelColor
        imageScaling = .scaleProportionallyDown
        toolTip = "Drag to move this pane"
        setAccessibilityLabel("Move Pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

/// The strip at the top of a pane: title, close button, and the handle for dragging the pane.
final class RiftPaneHeaderView: RiftFlippedView {
    private let titleField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let grip = RiftHeaderGripView()

    var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue; titleField.toolTip = newValue }
    }
    var showsCloseButton = true { didSet { updateVisibility() } }
    /// Show the grip for moving the pane (used when dragging the header moves the window).
    var showsGrip = false { didSet { updateVisibility() } }
    /// A bare header is an empty drag strip: no title or buttons.
    var isBare = false { didSet { updateVisibility(); needsDisplay = true } }
    /// Space kept clear at the leading edge, for the window's buttons.
    var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { needsLayout = true } } }
    var isFocused = false {
        didSet {
            titleField.textColor = isFocused ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }
    var onMouseDown: ((NSEvent) -> Void)?
    var onGripMouseDown: ((NSEvent) -> Void)? {
        get { grip.onMouseDown }
        set { grip.onMouseDown = newValue }
    }
    var onClose: (() -> Void)?

    private func updateVisibility() {
        titleField.isHidden = isBare
        closeButton.isHidden = isBare || !showsCloseButton
        grip.isHidden = isBare || !showsGrip
        needsLayout = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .center
        addSubview(titleField)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.setAccessibilityLabel("Close Pane")
        addSubview(closeButton)
        addSubview(grip)
        updateVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func closeClicked() { onClose?() }

    override func layout() {
        super.layout()
        let size: CGFloat = 16
        let y = ((bounds.height - size) / 2).rounded()
        var x = leadingInset + 6
        if !closeButton.isHidden {
            closeButton.frame = CGRect(x: x, y: y, width: size, height: size)
            x += size + 4
        }
        if !grip.isHidden {
            grip.frame = CGRect(x: x, y: y, width: size, height: size)
            x += size + 4
        }
        // Keep the title centred in the header when there's room, clear of the leading controls.
        let side = max(28, x + 2)
        let height = titleField.intrinsicContentSize.height
        let width = max(0, bounds.width - side * 2)
        let centred = CGRect(x: side, y: (bounds.height - height) / 2, width: width, height: height)
        if width >= min(titleField.intrinsicContentSize.width, 80) {
            titleField.frame = centred
        } else {
            titleField.frame = CGRect(
                x: x + 2, y: centred.minY, width: max(0, bounds.width - x - 8), height: height)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        if isFocused {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            bounds.fill(using: .sourceOver)
        }
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    // Clicks on the title count as clicks on the header (so the title drags the pane).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === titleField ? self : hit
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Draws the focus ring. Never intercepts the mouse.
final class RiftFocusBorderView: RiftFlippedView {
    var isFocused = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var color: NSColor? { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 2 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled, isFocused, lineWidth > 0 else { return }
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = max(0, cornerRadius - lineWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth
        (color ?? .controlAccentColor).setStroke()
        path.stroke()
    }
}

/// Shows where a dragged pane will land: a translucent accent fill with a solid 2pt outline.
final class RiftDropIndicatorView: RiftFlippedView {
    var color: NSColor? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 8 { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = color ?? .controlAccentColor
        let fill = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        accent.withAlphaComponent(0.25).setFill()
        fill.fill()
        let inner = bounds.insetBy(dx: 1, dy: 1)
        guard inner.width > 0, inner.height > 0 else { return }
        let radius = max(0, cornerRadius - 1)
        let stroke = NSBezierPath(roundedRect: inner, xRadius: radius, yRadius: radius)
        stroke.lineWidth = 2
        accent.setStroke()
        stroke.stroke()
    }
}

/// Exposes one divider to VoiceOver as an adjustable splitter.
final class RiftDividerAccessibilityElement: NSAccessibilityElement {
    var splitID = UUID()
    var axis: RiftAxis = .horizontal
    var position: Double = 0.5
    var label = "Divider"
    var adjust: ((_ step: Double) -> Bool)?

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { NSNumber(value: position) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 1) }
    override func accessibilityValueDescription() -> String? { "\(Int((position * 100).rounded())) percent" }
    // A horizontal split has a vertical divider line.
    override func accessibilityOrientation() -> NSAccessibilityOrientation {
        axis == .horizontal ? .vertical : .horizontal
    }
    override func accessibilityPerformIncrement() -> Bool { adjust?(1) ?? false }
    override func accessibilityPerformDecrement() -> Bool { adjust?(-1) ?? false }
}

/// Weak references to every live Rift view, so a pane drag can find drop targets in other windows.
@MainActor
enum RiftViewRegistry {
    private final class WeakBox {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private static var boxes: [WeakBox] = []

    static func register(_ view: NSView) {
        boxes.removeAll { $0.view == nil || $0.view === view }
        boxes.append(WeakBox(view))
    }

    static func unregister(_ view: NSView) {
        boxes.removeAll { $0.view == nil || $0.view === view }
    }

    static func views<V: NSView>(of type: V.Type) -> [V] {
        boxes.compactMap { $0.view as? V }
    }
}
