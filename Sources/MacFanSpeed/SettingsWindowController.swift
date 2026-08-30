import AppKit
import SwiftUI

/// Owns the Settings window.
///
/// SwiftUI's `Settings` scene is unreliable in a `LSUIElement` menu bar app —
/// there is no menu bar to put Cmd-, in, and opening it programmatically relies
/// on a private selector that has moved between releases. An ordinary window
/// under our own control behaves predictably.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(tab: SettingsView.Tab? = nil) {
        let monitor = FanMonitor.shared

        if window == nil {
            let view = SettingsView(
                monitor: monitor,
                settings: monitor.settings,
                presets: monitor.presets,
                installer: monitor.installer,
                initialTab: tab ?? .general
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Mac Fan Speed Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            WindowActivation.positionClearOfMenuBar(window)
        } else if let tab {
            // Recreate so a request for a specific tab actually lands there.
            window?.contentViewController = NSHostingController(
                rootView: SettingsView(
                    monitor: monitor,
                    settings: monitor.settings,
                    presets: monitor.presets,
                    installer: monitor.installer,
                    initialTab: tab
                )
            )
        }

        WindowActivation.present(window)
    }

    func windowWillClose(_ notification: Notification) {
        WindowActivation.windowClosed(window)
    }
}
