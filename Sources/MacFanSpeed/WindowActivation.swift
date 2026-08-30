import AppKit

/// Shared activation-policy handling for the app's windows.
///
/// A menu bar app runs as an `.accessory`, which cannot take focus or appear in
/// the app switcher. Opening a real window has to promote it to `.regular` and
/// closing one has to demote it back — but only once the *last* window is gone.
///
/// This lives in one place because the two window controllers had already
/// drifted: closing Settings demoted the app while the Sensors window was still
/// open, leaving a visible window that could no longer take focus.
@MainActor
enum WindowActivation {

    /// Promote the app so `window` can come to the front, and order it above the
    /// menu bar dropdown, which sits at an elevated window level.
    static func present(_ window: NSWindow?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Demote back to a menu bar accessory, unless another window is still open.
    static func windowClosed(_ closing: NSWindow?) {
        let othersOpen = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.canBecomeKey
        }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }

    /// Place a window in the left half of the screen.
    ///
    /// Centring puts it under the dropdown, which opens from the menu bar on the
    /// right, so the window appears to open behind the app.
    static func positionClearOfMenuBar(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.minX + max(24, (visible.width * 0.5 - size.width) / 2),
            y: max(visible.minY + 24, visible.maxY - size.height - 48)
        ))
    }
}
