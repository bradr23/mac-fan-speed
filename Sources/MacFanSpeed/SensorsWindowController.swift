import AppKit
import SwiftUI

/// Owns the Sensors window.
///
/// Sensor readings are what the app is *for*, not something you configure, so
/// they get their own window opened from the dropdown rather than a tab buried
/// in Settings. It is also the window someone leaves open while watching the
/// machine work, which a settings sheet is the wrong shape for.
@MainActor
final class SensorsWindowController: NSObject, NSWindowDelegate {
    static let shared = SensorsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SensorsView(monitor: FanMonitor.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Sensors"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 380, height: 560))
            window.minSize = NSSize(width: 320, height: 300)
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            WindowActivation.positionClearOfMenuBar(window)
        }

        WindowActivation.present(window)
    }

    func windowWillClose(_ notification: Notification) {
        WindowActivation.windowClosed(window)
    }
}
