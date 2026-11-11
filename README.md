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
    - The top-left corner, 44pt wide (`dragHandleWidth`), drags the pane. A grip fades in while the pointer is over it. The drag starts on the first mouse movement. A press that ends without moving is passed through to the pane's content as a normal click.
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
    - Pressing a pane header moves the window straight away, with no movement threshold. Double-clicking it performs the system titlebar double-click action: the window's frame view handles it when it can, and otherwise Rift reads the System Settings preference. Panes are then moved with the grip (≡) or by Option-dragging the header (`headerDragBehavior`).
    - While the pointer is over a pane header, and for the whole length of a pane drag, Rift sets the window's `isMovable` to `false`, using a reference-counted lock. Without it, macOS would start its own window drag in the header strip. The lock is recomputed from the pointer's real position, so it can't leak when a drag swallows mouse-exit events. Moving the window from a header waits for real mouse movement, then lifts the lock and calls `performDrag(with:)`.
    - Full screen and turning the mode off restore the normal layout.
    - `RiftHeadlessWindow` can also be used on its own.
- **Resize notices:** before you animate a `RiftView` to a new width (for example when folding a sidebar), call `beginContainerAnimation(toWidth:)`; call `endContainerAnimation()` when the animation is done.
  - Rift posts `RiftContainerAnimation.willBeginNotification` and `didEndNotification`, with the window as the object. The "will begin" notice carries `contentWidth` and `widthChange` in its `userInfo`.
  - Pane content listens through `RiftContainerAnimationObserver` and either freezes until the end (`.holdContent`) or resizes once, straight to its predicted final size (`.resizeToTarget`). That size is the pane's share of `widthChange`, in proportion to its share of `contentWidth`.
  - An observer gives up by itself if no end notice arrives within 2 seconds.
    - The `RiftView` listens for its own notices too. When an animation begins, it lays the panes out once at the size the view will end up, and holds each pane's content at that size, clipped, until the end notice arrives. Content therefore reflows once instead of on every frame.
- **Structural activity:** `structuralActivity` and `onStructuralActivityChange` report what is reshaping the panes right now: an animated layout change, a divider drag, a live window resize or a pane drag. Pane content can use this to stop scrollers flashing or to pause redraws.
- **Glass panes:** set `configuration.glass.isEnabled`.
  - On macOS 26 and later each pane sits on an `NSGlassEffectView` inside one `NSGlassEffectContainerView` behind the panes. Earlier systems use `NSVisualEffectView` with the `.popover` material.
  - Settings: style (regular or clear), tint, corner radius, outer rim colour and width, shadows, and `mergeFactor`.
  - Panes only merge when there is no gap between them.
  - Pane content must be partly transparent for the glass to show.
- **Accessibility:** each divider is an adjustable `AXSplitter`. Increment and decrement move it by 5%.
- **Reduce Motion:** animations are skipped when the system setting is on.

## Layout

| Target     | Contents                                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------ |
| `RiftCore` | Layout tree, geometry, divider-drag maths, drop zones, arrangement. Pure Swift and fully unit-tested.        |
| `Rift`     | `RiftView` (AppKit), the pane drag session, and the SwiftUI wrapper `RiftLayoutView`. Re-exports `RiftCore`. |
| `RiftDemo` | A demo app with a controls sidebar for trying every feature.                                                  |

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

The demo window has a controls sidebar on the right. It has buttons for splitting, closing, focus, swap,
resize, balance and zoom, plus switches for motion style, the focus border transition, fading, scroller
suppression, centre drops, glass, the headless window and headers. A status line shows the focused pane
and what is reshaping the panes. Drag panes by their top-left corner, and drag dividers, with the mouse.

| Shortcut | Action                |
| -------- | --------------------- |
| ⌘D / ⇧⌘D | Split right / down    |
| ⌘W       | Close pane            |
| ⌘N       | New window            |
| ⌃⌘S      | Hide or show controls |
