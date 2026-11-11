# Rift

A split-pane layout component for macOS. Use it from SwiftUI with `RiftLayoutView`: your app owns the layout, focus and zoom through bindings, and each pane is a SwiftUI view. A native AppKit view, `RiftView`, does the layout, motion, dividers and drag and drop underneath, and can also be used on its own.

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
    - A translucent accent-coloured indicator shows where the pane will land. It is drawn in a child window above the layout's window (`dropIndicatorUsesChildWindow`), so it shows over glass and every view.
    - A floating preview follows the pointer: your own view (`makeDragPreview`, or `dragPreview:` in SwiftUI), sized to fit, or else a snapshot of the pane. Escape cancels the drag.
    - Panes can also be dragged into another `RiftView` that has the same `groupIdentifier`.
    - Releasing outside every window tears the pane out (`onTearOut`).
- **Commands:**
    - Split, close (focus moves to the neighbouring pane), and focus by direction (wrapping at the edges).
    - Resize toward a direction and swap with a neighbour.
    - Balance panes evenly, optionally keeping dividers the user dragged, plus an auto-balance mode.
    - Zoom one pane to fill the view. The zoom animates on the chrome curve with the pane drawn above the others, which stay laid out behind it: they fade out over the first half of the zoom and, when it is undone, fade back in over the second half (smoothstep). Divider lines fade with them.
- **Focus:**
    - Clicking anywhere in a pane focuses it.
    - Optional: focus follows the mouse.
    - Focus border colour: any `NSColor`, or a named preset (`focusBorderPreset`: accent, red, blue, green, yellow, cyan, magenta, foreground) taken from `colorPalette`, which you can set to your app's or terminal theme's colours.
    - Accent focus border, 2pt, stroked with a gradient (the colour mixed 10% toward white, the colour, and 10% toward black, in OKLab) at 135°. Corners that meet the window's corners take `layoutCornerRadius`, and divider lines under the border are hidden (`focusBorderCoversDividers`).
    - Unfocused panes can lose their surface look, their content opacity, or both (`inactivePaneFade`).
- **Motion:** every animated layout change is one plan, sampled each frame:
    - Panes move on the pane curve (a spring that settles in its own time).
    - New panes pop in (from 87% size while fading in) or, with `paneTransition = .edgeGrowth`, grow out of the edge they were split from. A growing pane is never drawn shorter than 32pt, and its opacity follows a smoothstep of how much of it has grown past those 32pt. Closed panes do the reverse.
    - Each divider line fades on its own: new lines fade in, removed lines fade out.
    - A change that interrupts another starts from where the panes are now, and a pane still growing keeps growing from its current size and opacity.
    - `paneContentSizing = .pinnedDuringMotion` holds content at the larger of its start and end size until the motion ends.
- **Sidebar:** `RiftSidebarContainerView` (SwiftUI: `RiftSidebarSplitView`) puts a sidebar on the left or right of your content.
    - 240pt wide by default; drag its inner edge to resize it between 167pt and 60% of the window (at most 480pt).
    - Fold it with its toggle button (28×28 beside the window buttons: the `sidebar.left` or `sidebar.right` symbol at 13pt, in the label colour at 70% until hovered and 32% when disabled, with a round hover background at 8% of that colour (7.5% in light mode) that fades in over 0.14s; `toggleShortcut` adds the shortcut to its tooltip), `toggleSidebar()`, or a two-finger swipe toward its side (44pt, mostly sideways; `swipe` can require ⌥ or turn it off). The fold runs on the chrome curve: the sidebar stays put and a mask covers it as the content slides over.
    - By default the window keeps its width and the content takes the space (layouts inside are told before it starts). With `preservesWindowWidth` off, folding shrinks the window by the sidebar's width (never below 480pt, or 720pt minus the sidebar) and unfolding grows it back, so the panes keep their size.
    - A window that already fills its screen (within 64pt of its width) keeps its width when folding. Folds take the curve's settling time (0.3s for a bezier) and are skipped while the window is hidden or covered. Once folded, the sidebar fades out over 0.16s and is hidden.
    - The window's minimum width follows the sidebar (720pt open; less once a fold has shrunk it), and a narrower window is widened (`managesWindowMinimumWidth`).
    - Right-clicking the toggle shows a menu for the side (Left Side, Right Side) and density (Comfortable, Compact) when you handle `onPositionChange` / `onDensityChange`.
    - In compact density a hairline separates the sidebar from the panes (`dividerColor`).
    - The sidebar's top is a title row (50pt, 38pt compact; `titleRowHeight`, or `riftSidebarTitleRowHeight` in the SwiftUI environment) that drags the window, and double-clicking it does the titlebar's double-click action. Start sidebar content below it.
    - `accessories` puts the sidebar's own buttons in that row, on the toggle's line: 28×28, 2pt apart, from 10pt (6pt compact) in from the outer edge toward the window buttons. The ones that don't fit go into a "more" menu.
    - A swipe that starts over something that scrolls sideways is left to it.
    - Layouts inside keep room in their top pane headers for the window buttons and the toggle: none while a left sidebar is open, growing to 116pt as it folds (76pt beside a right sidebar).
    - `RiftTitlebarMetrics.sidebar(_:)` gives the headless window the matching 42pt titlebar and button offset.
- **Closing busy panes:** give `paneActivity` a short phrase for panes that are busy ("is still working"). Closing them (`close`, `closeOthers`) first shows a card over the layout, which is dimmed except for the pane in question. It lists the busy panes (click one to go to it; at most three, then a count), with Cancel (Escape) and Close (Return).
- **Headless windows:** set `configuration.windowStyle = .headless`.
    - The titlebar and title are hidden, and content runs edge to edge.
    - The real close, minimise and zoom buttons stay, centred in the top row of pane headers. Rift sets the window's titlebar height (`customTitlebarHeight` on the frame view) and the button group offset (`standardWindowButtonGroupOffset`), so AppKit lays the buttons out itself. These are private AppKit settings: Rift checks that the window responds to them first and, where it doesn't, resizes the titlebar container with public `NSView` calls instead.
    - Panes under the buttons leave room for them.
    - Pressing a pane header moves the window straight away, with no movement threshold. Double-clicking it performs the system titlebar double-click action: the window's frame view handles it when it can, and otherwise Rift reads the System Settings preference. Panes are then moved with the grip (≡) or by Option-dragging the header (`headerDragBehavior`).
    - While the pointer is over a pane header, and for the whole length of a pane drag, Rift sets the window's `isMovable` to `false`, using a reference-counted lock. Without it, macOS would start its own window drag in the header strip. The lock is recomputed from the pointer's real position, so it can't leak when a drag swallows mouse-exit events. Moving the window from a header waits for real mouse movement, then lifts the lock and calls `performDrag(with:)`.
    - Full screen and turning the mode off restore the normal layout.
    - `RiftHeadlessWindow` can also be used on its own.
- **Resize notices:** before you animate a `RiftView` to a new width (for example when folding a sidebar), call `beginContainerAnimation(toWidth:)`; call `endContainerAnimation()` when the animation is done.
  - Rift posts `RiftContainerAnimation.willBeginNotification` and `didEndNotification`, with the window as the object. The "will begin" notice carries `contentWidth` and `widthChange` in its `userInfo`.
  - Pane content listens through `RiftContainerAnimationObserver` and either freezes until the end (`.holdContent`) or resizes once, straight to its predicted final size (`.resizeToTarget`). That size is the pane's share of `widthChange`, in proportion to its share of `contentWidth`.
  - An observer gives up by itself if no end notice arrives within 2 seconds.
    - The `RiftView` listens for its own notices too. When an animation begins, it holds each pane's content at the larger of its current size and its final size, clipped to the pane, until the last end notice arrives. Content therefore reflows once instead of on every frame, and never leaves a gap. Animations that overlap (a fold reversed halfway) are counted, so the content is only released when all of them have ended.
- **Structural activity:** `structuralActivity` and `onStructuralActivityChange` report what is reshaping the panes right now: an animated layout change, a divider drag, a live window resize or a pane drag. Pane content can use this to stop scrollers flashing or to pause redraws. While anything reshapes, views that adopt `RiftScrollerSuppressing` are asked to hide their own scrollers; other scroll views' scrollers are faded out.
- **Presentation:** each pane's content (and any object added with `addPresentationObserver(_:for:)`) hears whether the layout has settled, the animated zoom fraction, its content, target and surface sizes, and how much content is cut off past the trailing edge.
    - It also hears where to put a title: `titleLeadingInset` / `titleTrailingInset` (the room kept for the window buttons and a sidebar's toggle, which changes as the sidebar folds) and `titleRowHeight` (for panes along the top of a headless window, a row centred on the window buttons). Lay a title out between the insets in that row and it lines up with the buttons and moves aside for them.
- **Pane surfaces:** Rift draws no pane background itself. Set `configuration.paneSurface` to draw one behind each pane's content, and `configuration.windowSurface` for one behind the whole layout (a window material with a tint and backdrop, and a soft inner shadow along the window's edge).
  - `RiftPaneSurfaces.modern(.comfortable)` gives glass cards: 10pt corners, a tinted glass layer (liquid glass on macOS 26 and later, a visual-effect material before), a light fill, and in dark mode an overlay backdrop. `.modern(.compact)` gives touching panes with a 1pt line drawn over their shared edges (`metrics.lineThickness`), a faint backdrop on the focused pane in dark mode, and near-white fills in light mode. The `.comfortable` and `.compact` configuration presets set the matching window surface too.
  - Each surface has a style per state (pane, focused pane, and both again for background windows) and per appearance. A style stacks shadows, a backdrop, glass, two fills and strokes, and sets the content's opacity.
  - For your own surface, adopt `RiftPaneSurfaceProviding`: make a view, update it for each state, and give the content opacity.
  - Content must be partly transparent for a glass surface to show.
- **Themes:** `RiftTheme` builds a full set of colour roles (about 70: canvas, surfaces, sidebar, text, lines, controls, selection, accent and status colours with their solid, container and border forms, and the terminal colours) from a terminal-style palette: background, foreground, cursor (the accent), selection and the 16 ANSI colours.
    - Surfaces, lines and secondary text are the background with its OKLCH lightness moved toward the foreground's; containers mix the background toward their colour in OKLab; controls and dimmed accents are translucent overlays.
    - Eight built-in themes (Graphite, Harbor, Ember, Nightshade, Paper, Sea Glass, Dune, Frost); load more from JSON with `RiftTheme.load(from:)`, override any role, and pair a light and a dark theme with `RiftThemeSelection`.
    - Set `configuration.theme`: the built-in surfaces' tints take the theme's canvas, the border presets its accent and terminal colours, divider lines its text colour, and the drop highlight its accent. The sidebar's `theme` colours its background, buttons and divider.
    - Pane content gets the theme in the SwiftUI environment (`riftThemeSelection`, or `RiftThemeReader { theme in … }`); `NSColor.rift(_:in:)` and `Color(rift:)` turn roles into colours.
- **Accessibility:** each divider is an adjustable `AXSplitter`. Increment and decrement move it by 5%.
- **Reduce Motion:** animations are skipped when the system setting is on.

## Layout

| Target     | Contents                                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------ |
| `RiftCore` | Layout tree, geometry, divider-drag maths, drop zones, arrangement. Pure Swift and fully unit-tested.        |
| `Rift`     | `RiftView` (AppKit), the pane drag session, and the SwiftUI wrapper `RiftLayoutView`. Re-exports `RiftCore`. |
| `RiftDemo` | Rift Workbench: a sidebar, a split layout of small tools, and settings for every feature. |

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
@State var focused: String?
@State var zoomed: String?
let controller = RiftController<String>()

RiftLayoutView(
    layout: $layout, focusedPane: $focused, zoomedPane: $zoomed,
    configuration: .comfortable, controller: controller,
    onLayoutSettled: { print("settled") }
) { pane in
    MyPane(id: pane.paneID)
        .opacity(pane.isFocused ? 1 : 0.9)
        .redacted(reason: pane.presentation.isLayoutSettled ? [] : .placeholder)
}
// controller.split(edge: .bottom, newPane: "b")
```

Each pane's content gets a `RiftPaneContext`: its ID, whether it is focused, its accessibility label,
and its `presentation` (whether the layout has settled, the zoom, its content and target sizes). The
content updates when any of these change. Rift writes every change the user makes (drags, drops,
closes, focus, zoom) back through the bindings. `onTearOut` hands you a pane dropped outside every
window, already removed, to open somewhere else.

Hosting views ignore the window's safe area, so content runs under a headless titlebar; leave room for
the window buttons yourself if a pane needs it.

### Making a custom handle draggable

Call `riftView.trackPaneDrag(paneID, startingWith: event)` from your view's `mouseDown(with:)`.

## Run

```bash
swift test
```

```bash
swift run RiftDemo
```

The demo is **Rift Workbench**, a SwiftUI app built on `RiftSidebarSplitView` and `RiftLayoutView`.

- The **navigator** sidebar lists the open panes (click to focus; right-click to close or close the others), adds tools beside the focused pane, and holds the settings: card, tile or plain looks; motion style; pop-in or edge-growth panes; border transition, colour swatches and gradient; what unfocused panes lose; content sizing while moving; balancing; asking before closing busy panes; and the sidebar's side, swipe and window-width behaviour. Fold it with its toggle, a sideways swipe, or ⌥⌘S.
- Each pane is a **tool** that shows a feature at work:
    - **Notes:** a text editor (focus and unfocused fading).
    - **Inspector:** the pane's live presentation (settled, zoom fraction, content, target and surface sizes, what is reshaping).
    - **Log:** a growing log in an `NSScrollView` that hides its own scroller while the layout moves (`RiftScrollerSuppressing`).
    - **Orbit:** an animation that pauses while the layout moves.
    - **Clock:** a clock that grows with the zoom fraction.
- Log and Orbit count as busy, so closing them shows the confirmation card. Dragged panes show a small card under the pointer; dropping one outside the window opens it in a new one.

| Shortcut         | Action                    |
| ---------------- | ------------------------- |
| ⌘D / ⇧⌘D         | Split right / down        |
| ⌘W               | Close pane                |
| ⌥⌘W              | Close other panes         |
| ⇧⌘↩              | Zoom pane                 |
| ⌥⌘=              | Balance                   |
| ⌥⌘ arrows        | Move focus                |
| ⌃⌘ arrows        | Swap with a neighbour     |
| ⌥⌘S              | Fold or unfold the sidebar |
| ⌘N               | New window                |
