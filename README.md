# Rift

A split-pane layout component for macOS (AppKit + SwiftUI).

## Features

- **Layout tree:** an immutable binary tree (`RiftLayout`) with Codable persistence and validation.
- **Splitting:** split a single pane, or split the full width or height of the whole layout (`wrapping`).
- **Divider dragging:**
    - The pointer grabs an 8pt hit area around each divider.
    - Dividers snap to the centre (10pt to snap, 16pt to release) and give a haptic tick when they snap.
    - Minimum pane sizes are enforced.
    - Grabbing a point where two dividers cross moves both at once.
    - Double-clicking a divider centres it.
- **Top strip (default, no header bars):** each pane has an invisible strip along its top, 28pt tall (`headerHeight`).
    - The top-left corner, 44pt wide (`dragHandleWidth`), drags the pane. A grip fades in while the pointer is over it.
    - On panes at the top of a headless window, the rest of the strip moves the window, and double-clicking it acts like a titlebar double-click. On all other panes, the rest of the strip does nothing and clicks reach the content.
    - On the pane under the window buttons, the corner handle starts just after the buttons.
    - Set `showsPaneHeaders = true` for header bars with a title and close button instead.
- **Pane drag and drop:** drag a pane by its corner handle (or by its header, with header bars).
    - The drop zone is left, right, top or bottom when the pointer is in an edge band. Each band is 80pt wide, clamped to between ¼ and ⅓ of the pane. Elsewhere the zone is the centre, and dropping there swaps the two panes.
    - A translucent accent-coloured indicator shows where the pane will land.
    - A floating snapshot of the pane follows the pointer. Escape cancels the drag.
    - Panes can also be dragged into another `RiftView` that has the same `groupIdentifier`.
    - Releasing outside every window tears the pane out (`onTearOut`).
- **Commands:**
    - Split, close (focus moves to the neighbouring pane), and focus by direction (wrapping at the edges).
    - Resize toward a direction and swap with a neighbour.
    - Balance panes evenly, optionally keeping dividers the user dragged, plus an auto-balance mode.
    - Zoom one pane to fill the view.
- **Focus:**
    - Clicking anywhere in a pane focuses it.
    - Optional: focus follows the mouse.
    - Accent focus border.
    - Optional fading of unfocused panes.
- **Headless windows:** set `configuration.windowStyle = .headless`.
    - The titlebar and title are hidden, and content runs edge to edge.
    - The real close, minimise and zoom buttons stay, centred in the top row of pane headers. Rift resizes the titlebar container using public `NSView` calls only, and re-applies the layout whenever AppKit redoes it.
    - Panes under the buttons leave room for them.
    - Dragging a pane header moves the window, and double-clicking it follows the system's titlebar double-click setting. Panes are then moved with the grip (≡) or by Option-dragging the header (`headerDragBehavior`).
    - While the pointer is over a pane header, and for the whole length of a pane drag, Rift sets the window's `isMovable` to `false`, using a reference-counted lock. Without it, macOS would start its own window drag in the header strip. The lock is recomputed from the pointer's real position, so it can't leak when a drag swallows mouse-exit events. Moving the window from a header waits for real mouse movement, then lifts the lock and calls `performDrag(with:)`.
    - Full screen and turning the mode off restore the normal layout.
    - `RiftHeadlessWindow` can also be used on its own.
- **Accessibility:** each divider is an adjustable `AXSplitter`. Increment and decrement move it by 5%.
- **Reduce Motion:** animations are skipped when the system setting is on.

## Layout

| Target     | Contents                                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------ |
| `RiftCore` | Layout tree, geometry, divider-drag maths, drop zones, arrangement. Pure Swift and fully unit-tested.        |
| `Rift`     | `RiftView` (AppKit), the pane drag session, and the SwiftUI wrapper `RiftLayoutView`. Re-exports `RiftCore`. |
| `RiftDemo` | A demo app with two windows and keyboard shortcuts.                                                          |

## Usage

### AppKit

```swift
import Rift

let view = RiftView<String>(layout: .pane("a")) { id in MyPaneView(id: id) }
view.onLayoutChange = { layout, reason in save(layout) }
view.onTearOut = { pane, content, screenPoint in
    let newView = RiftView<String> { _ in NSView() }
    newView.adopt(pane, content: content, reason: .tearOut)
    // put newView in a new window near screenPoint
}
view.split(edge: .right, newPane: "b")
view.moveFocus(.left)
view.resize(toward: .right)   // 5% of the split
view.toggleZoom()
```

Changes you make in code (`setLayout`, `focusedPane =`) don't fire the callbacks. User actions and
the command methods do.

### SwiftUI

```swift
@State var layout: RiftLayout<String>? = .pane("a")
let controller = RiftController<String>()

RiftLayoutView(layout: $layout, controller: controller) { id in
    Text(id)
}
// controller.split(edge: .bottom, newPane: "b")
```

### Making a custom handle draggable

Call `riftView.trackPaneDrag(paneID, startingWith: event)` from your view's `mouseDown(with:)`.

## Run

```bash
swift test
```

```bash
swift run RiftDemo
```

Demo shortcuts:

| Shortcut    | Action                    |
| ----------- | ------------------------- |
| ⌘D / ⇧⌘D    | Split right / down        |
| ⌥⌘D / ⇧⌥⌘D  | Split full width / height |
| ⌘W          | Close pane                |
| ⌥⌘ + arrow  | Move focus                |
| ⌃⌘ + arrow  | Grow the pane             |
| ⇧⌥⌘ + arrow | Swap with neighbour       |
| ⌃⌘=         | Balance panes             |
| ⇧⌘↩         | Zoom the pane             |
| ⌃⌘H         | Toggle header bars        |
| ⌃⌘T         | Toggle headless window    |
