import AppKit

/// Stops macOS from dragging a window while Rift needs the mouse.
///
/// In a headless window the pane headers sit where the titlebar was. The window server treats
/// that strip as a drag region and starts moving the window before the app even sees the mouse,
/// so a pane drag would drag the whole window along with it. Holding a lock sets
/// `isMovable = false`; when the last lock on a window is released the original value comes back.
@MainActor
enum RiftWindowMovementLock {
    private final class Entry {
        var count = 0
        var wasMovable = true
    }

    private static let entries = NSMapTable<NSWindow, Entry>.weakToStrongObjects()

    /// Locks `window` and returns a token. Release it once with `RiftMovementLockToken.release()`.
    static func acquire(_ window: NSWindow) -> RiftMovementLockToken {
        let entry = entries.object(forKey: window) ?? {
            let entry = Entry()
            entry.wasMovable = window.isMovable
            entries.setObject(entry, forKey: window)
            return entry
        }()
        entry.count += 1
        if window.isMovable { window.isMovable = false }
        return RiftMovementLockToken(window: window)
    }

    fileprivate static func release(_ window: NSWindow) {
        guard let entry = entries.object(forKey: window) else { return }
        entry.count -= 1
        guard entry.count <= 0 else { return }
        window.isMovable = entry.wasMovable
        entries.removeObject(forKey: window)
    }

    static func isLocked(_ window: NSWindow) -> Bool { entries.object(forKey: window) != nil }
}

/// One hold on a window's movement lock. Releasing twice is harmless.
@MainActor
final class RiftMovementLockToken {
    private weak var window: NSWindow?
    private var isReleased = false

    fileprivate init(window: NSWindow) { self.window = window }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        if let window { RiftWindowMovementLock.release(window) }
    }
}
