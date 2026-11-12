# Rift

A split-pane layout component for macOS, with the window chrome that goes around it: a sidebar, tabs, floating panes, a grid of items and themes.

Use it from SwiftUI (`RiftLayoutView`): your app owns the layout, focus and zoom through bindings, and each pane is a SwiftUI view. The AppKit view underneath, `RiftView`, does the layout, motion, dividers and drag and drop, and can be used on its own.

## Features

**Layout**

- **Layout tree:** `RiftLayout` is an immutable, Codable binary tree of panes and splits.
- **Splitting:** split one pane, or the full width or height of the whole layout.
- **Dividers:** drag to resize, with snapping to the centre, minimum pane sizes and a resize cursor. Dragging where two dividers cross moves both; double-clicking centres one.
- **Pane drag and drop:** drag a pane by its corner handle (or its header) onto an edge of another pane to move it there, or onto the centre to swap. Panes can move between views with the same `groupIdentifier`, and dropping one outside every window tears it out (`onTearOut`).
- **Commands:** split, close, focus by direction, resize, swap with a neighbour, balance (with an auto-balance mode) and zoom one pane to fill the view.
- **Focus:** click to focus, optional focus-follows-mouse, a gradient focus border in any colour or a preset, and optional dimming of unfocused panes (`inactivePaneFade`).
- **Motion:** layout changes animate on a spring. New panes pop in or grow from the edge they were split from (`paneTransition`), and a change that interrupts another carries on from where the panes are. Animations are skipped with Reduce Motion on.
- **Floating panes:** `float`, `dock`, `toggleFloating` and `setMinimised` move panes into layers above the tiled layout. A layer has its own split layout, can be moved and resized, snaps to the edges, and minimises to a capsule along the bottom.

**Panes**

- **Top strip (default):** an invisible strip along each pane's top. Its corner drags the pane, the rest moves the window on panes along the window's top, and a right-click opens the pane's menu.
- **Header bars:** `showsPaneHeaders = true` gives each pane a title bar with a close button, your own icon buttons (`paneActions`), a menu (`paneMenu`) and rename-in-place (`onRenamePane`).
- **Pane context:** content is told whether it is focused and hovered, and through `presentation` whether the layout has settled, the zoom fraction, its sizes and where to put a title so it clears the window buttons. Each value is observed on its own, so content is rebuilt only for the values it reads.
- **Closing busy panes:** give `paneActivity` a phrase for busy panes and closing them asks first.
- **Surfaces:** `configuration.paneSurface` and `windowSurface` draw behind panes and the layout. `RiftPaneSurfaces.modern(_:)` gives glass cards (comfortable) or touching panes with hairlines (compact); adopt `RiftPaneSurfaceProviding` for your own.
- **Structural activity:** `structuralActivity` reports what is reshaping the panes (an animation, a divider drag, a window resize, a pane drag), so content can pause redraws. Scroll views that adopt `RiftScrollerSuppressing` hide their scrollers meanwhile.

**Window chrome**

- **Sidebar:** `RiftSidebarSplitView` (AppKit: `RiftSidebarContainerView`) puts a resizable sidebar on either side. It folds with a toggle button, a shortcut or a sideways swipe; the window can keep its width or shrink with it. It has a title row with your own buttons (`accessories`) and an optional footer row (`footerAccessories`), and it keeps the window from getting narrower than the sidebar allows.
- **Tabs:** `RiftTabBar` is a row of tabs across the top, and `RiftTabList` shows the same tabs as sidebar rows. Tabs can be reordered by dragging, renamed, closed, and torn off into a new window. A pane dragged over a tab opens it, and dropped between tabs it becomes a new tab.
- **Headless windows:** `windowStyle = .headless` hides the titlebar so panes run edge to edge. The real window buttons stay, and panes under them leave room.
- **Navigator and minimap:** `RiftPaneNavigator` is a searchable list of panes in groups (tabs, say). `RiftPaneMinimap` draws a small picture of a layout with the focused pane highlighted.
- **Container animations:** call `beginContainerAnimation(toWidth:)` and `endContainerAnimation()` around your own width animation and pane content reflows once instead of on every frame.

**Grid**

- `RiftGrid` (AppKit: `RiftGridView`) lays interactive views out in a scrolling grid of equal cells, for icon views of apps, folders and the like.
- **Columns:** they follow the width (`.fitting`) or are a fixed number (`.fixed(4)`). `RiftGridMetrics` also sets the cell size, spacing, insets and a row limit.
- **Selecting:** click, ⌘-click, Shift-click, a selection rectangle, arrow keys and ⌘A. A double-click or Return opens the selection (`onOpen`).
- **Dragging:** drag an item or the selection to reorder it, onto an item that takes drops (`canDropOnto`, `onDropOnto`), or into another grid with the same `dragGroup`.
- **Cells:** your own views, created only for the rows in view. Content reads `cell.isSelected`, `isHovered`, `isDropTarget` and `isEmphasized`. Turn on `forwardsClicksToContent` for cells with their own buttons.

**Themes**

- `RiftTheme` builds about 70 colour roles (canvas, surfaces, text, lines, controls, accent, status and terminal colours) from a terminal-style palette: background, foreground, cursor, selection and the 16 ANSI colours.
- There are eight built-in themes. Load more from JSON with `RiftTheme.load(from:)`, override any role, and pair a light and a dark theme with `RiftThemeSelection`.
- Set `configuration.theme` and the surfaces, borders, dividers and drop highlight follow it. Pane content reads it from the environment (`riftThemeSelection`); `Color(rift:)` and `NSColor.rift(_:in:)` turn roles into colours.

**Accessibility:** each divider is an adjustable splitter, panes offer move actions, and grid cells are labelled (`label:`).

## Usage

### SwiftUI

```swift
import Rift

@State var layout: RiftLayout<String>? = .pane("a")
@State var focused: String?
let controller = RiftController<String>()

RiftLayoutView(
    layout: $layout, focusedPane: $focused,
    configuration: .comfortable, controller: controller
) { pane in
    MyPane(id: pane.paneID)
        .opacity(pane.isFocused ? 1 : 0.9)
        .redacted(reason: pane.presentation.isLayoutSettled ? [] : .placeholder)
}
// controller.split(edge: .bottom, newPane: "b")
```

Rift writes every change the user makes (drags, drops, closes, focus, zoom) back through the bindings. Pane content ignores the window's safe area, so it runs under a headless titlebar.

Tabs, each with its own layout:

```swift
@State var tabs = [RiftTab(id: 1, title: "Main")]
@State var selection: Int? = 1
@State var layouts: [Int: RiftLayout<String>] = [1: .pane("a")]

VStack(spacing: 0) {
    RiftTabBar(tabs: $tabs, selection: $selection) {
        tabs.append(RiftTab(id: tabs.count + 1, title: "New"))
    }
    ZStack {
        ForEach(tabs, id: \.id) { tab in
            RiftLayoutView(layout: Binding(get: { layouts[tab.id] }, set: { layouts[tab.id] = $0 })) {
                MyPane(id: $0)
            }
            .layoutHidden(tab.id != selection)
        }
    }
}
```

Keep every tab's layout alive and hide the background ones with `layoutHidden(_:)`, so a pane dragged out of a hidden tab can still land.

A grid:

```swift
@State var apps: [URL] = []
@State var selection: Set<URL> = []

RiftGrid(items: $apps, selection: $selection, metrics: RiftGridMetrics(columns: .fixed(4))) { cell in
    AppIcon(url: cell.id).opacity(cell.isHovered ? 1 : 0.9)
}
```

Reorders and moves between grids are written back to `items`.

### AppKit

```swift
let view = RiftView<String>(layout: .pane("a")) { id in MyPaneView(id: id) }
view.onLayoutChange = { layout, reason in save(layout) }
view.split(edge: .right, newPane: "b")
view.moveFocus(.left)
view.toggleZoom()
```

Changes you make in code (`setLayout`, `focusedPane =`) don't fire the callbacks; user actions and the command methods do. To drag a pane from your own handle, call `trackPaneDrag(_:startingWith:)` from its `mouseDown(with:)`.

## Project

| Target     | Contents                                                              |
| ---------- | --------------------------------------------------------------------- |
| `RiftCore` | The layout tree and all the maths. Pure Swift and unit-tested.        |
| `Rift`     | The AppKit views and their SwiftUI wrappers. Re-exports `RiftCore`.   |
| `RiftDemo` | Rift Files, a Finder-style browser that uses every feature.           |

Sources are grouped by feature: `Layout`, `Floating`, `Sidebar`, `Tabs`, `Grid`, `Window`, `Appearance`, `SwiftUI` and `Support` in `Rift`, with matching folders in `RiftCore`.

## Run

```bash
swift test
```

```bash
swift run RiftDemo
```

The demo is **Rift Files**, a small file browser. It only reads: it lists folders, previews files, and opens a file in its own app on a double-click.

- **Sidebar:** places, the tabs, the panes in the current tab with a minimap, buttons to add panes, and View Options for every setting (theme, look, motion, focus, layout, panes, tabs, sidebar).
- **Tabs:** each holds its own layout. They sit in the sidebar by default; View Options › Tabs moves them to a bar across the top.
- **Panes:** a browser (icons in a `RiftGrid`, or a table), Quick Look preview, info about the selection and the pane's live presentation, folder sizes, and an activity log.
- **Themes:** it also lists any JSON theme files in `Sources/RiftDemo/Themes`. Only `0x96f.json` is in the repository; other files there are ignored by git.

Dropping an icon onto a folder or into another browser only logs what a file manager would do; the demo never changes your files.

| Shortcut      | Action                            |
| ------------- | --------------------------------- |
| ⌘D / ⇧⌘D      | Split right / down                |
| ⌘W / ⌥⌘W      | Close pane / close other panes    |
| ⇧⌘↩           | Zoom pane                         |
| ⌥⌘=           | Balance                           |
| ⌥⌘ arrows     | Move focus                        |
| ⌃⌘ arrows     | Swap with a neighbour             |
| ⌥⌘F / ⌥⌘M     | Float or dock pane / minimise it  |
| ⌘P            | Go to pane                        |
| ⌥⌘S           | Fold or unfold the sidebar        |
| ⌘N            | New window                        |
| ⌘T / ⇧⌘W      | New tab / close tab               |
| ⇧⌘] / ⇧⌘[     | Next / previous tab               |
| ⌘[ / ⌘] / ⌘↑  | Back / forward / enclosing folder |
