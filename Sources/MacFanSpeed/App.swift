import AppKit
import SwiftUI
import SMCKit

@main
struct MacFanSpeedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = FanMonitor.shared

    var body: some Scene {
        MenuBarExtra {
            DropdownView(monitor: monitor)
        } label: {
            Text(monitor.menuBarText)
                .monospacedDigit()
        }
        // Charts and controls need a real window; the default .menu style only
        // renders native menu items.
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FanMonitor.shared.start()

        if ProcessInfo.processInfo.environment["MFS_SELFTEST"] == "1" {
            runSelfTest()
        }
        if ProcessInfo.processInfo.environment["MFS_TEST_LOGIN"] == "1" {
            runLoginItemTest()
        }
        if ProcessInfo.processInfo.environment["MFS_PREVIEW"] == "1" {
            showPreviewWindow()
        }
        if let percent = ProcessInfo.processInfo.environment["MFS_TEST_MANUAL"],
           let fraction = Double(percent) {
            runManualControlTest(percent: fraction / 100)
        }
        // Opening Settings normally means clicking the menu bar item, which
        // needs Accessibility permission to automate.
        if ProcessInfo.processInfo.environment["MFS_SENSORS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                SensorsWindowController.shared.show()
                for window in NSApp.windows where window.title == "Sensors" {
                    window.level = .floating
                    window.orderFrontRegardless()
                }
            }
        }
        if let tab = ProcessInfo.processInfo.environment["MFS_SETTINGS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                SettingsWindowController.shared.show(
                    tab: SettingsView.Tab.allCases.first { $0.rawValue.lowercased() == tab.lowercased() }
                )
                // Float it so a screenshot catches it even when another app has
                // focus, the same reason the dropdown preview floats.
                for window in NSApp.windows where window.title.contains("Settings") {
                    window.level = .floating
                    window.orderFrontRegardless()
                }
            }
        }
    }

    /// Exercise the app's own control path end to end: enter manual mode, hold a
    /// target through the daemon, then quit so the shutdown release runs.
    ///
    /// The CLI and daemon are covered by scripts/verify-phase3.sh; this covers
    /// the part only the app does, which cannot be driven by clicking the menu
    /// bar without Accessibility permission.
    private func runManualControlTest(percent: Double) {
        let monitor = FanMonitor.shared

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            var out = "manualtest.helper: \(monitor.helper.status)\n"
            guard monitor.helper.status.isReady else {
                out += "manualtest.result: SKIPPED (helper not available)\n"
                FileHandle.standardError.write(Data(out.utf8))
                NSApp.terminate(nil)
                return
            }

            let baseline = monitor.fans.map(\.actualRPM)
            let requested = monitor.fans.map { $0.rpm(forPercent: percent) }
            out += "manualtest.baselineRPM: \(baseline.map { Int($0) })\n"
            out += "manualtest.requestedRPM: \(requested.map { Int($0) })\n"
            FileHandle.standardError.write(Data(out.utf8))

            monitor.setPercent(percent)
            monitor.setMode(.manual)

            // Give the firmware time to yield and the fans time to spin up.
            var ticks = 0
            var sawFailsafe = false
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
              // Scheduled on the main run loop, so this always fires on main.
              MainActor.assumeIsolated {
                ticks += 1
                let rpm = monitor.fans.map { Int($0.actualRPM) }
                var line = "manualtest.t+\(ticks * 3)s rpm=\(rpm) mode=\(monitor.mode.rawValue)"
                if monitor.mode == .auto { sawFailsafe = true }
                if let message = monitor.failsafeMessage {
                    sawFailsafe = true
                    line += " failsafe=\"\(message)\""
                }
                line += (monitor.lastControlError.map { " error=\($0)" } ?? "") + "\n"
                FileHandle.standardError.write(Data(line.utf8))

                guard ticks >= 8 else { return }
                timer.invalidate()

                let peak = monitor.fans.map(\.actualRPM).max() ?? 0
                let want = requested.max() ?? 0
                var summary = "manualtest.peakRPM: \(Int(peak)) of \(Int(want)) requested\n"
                // Reported separately from the speed result: a failsafe trip is a
                // correct outcome when the machine is hot, and asserting on it
                // directly beats inferring it from the fans not spinning up.
                summary += "manualtest.failsafeFired: \(sawFailsafe)\n"
                summary += "manualtest.finalMode: \(monitor.mode.rawValue)\n"
                summary += "manualtest.result: \(peak > want * 0.75 ? "PASS" : "FAIL")\n"
                summary += "manualtest.quitting — the shutdown path must release the fans\n"
                FileHandle.standardError.write(Data(summary.utf8))
                NSApp.terminate(nil)
              }
            }
        }
    }

    /// Round-trip the login item: enable, verify, disable, verify.
    ///
    /// Toggling it in Settings needs a click, and the state lives outside the app
    /// (a LaunchAgent plist), so this checks the whole path leaves nothing behind.
    private func runLoginItemTest() {
        let settings = FanMonitor.shared.settings
        var out = ""

        settings.refreshLoginItemState()
        out += "login.initial: \(settings.loginItemState)\n"
        out += "login.usesModernAPI: \(settings.usesModernLoginAPI)\n"

        let enableError = settings.setLaunchAtLogin(true)
        out += "login.afterEnable: \(settings.loginItemState)"
            + (enableError.map { " error=\($0)" } ?? "") + "\n"
        let plistExists = FileManager.default.fileExists(atPath: LoginItemManager.plistURL.path)
        out += "login.plistWritten: \(plistExists)\n"

        let disableError = settings.setLaunchAtLogin(false)
        out += "login.afterDisable: \(settings.loginItemState)"
            + (disableError.map { " error=\($0)" } ?? "") + "\n"
        let plistGone = !FileManager.default.fileExists(atPath: LoginItemManager.plistURL.path)
        out += "login.plistRemoved: \(plistGone)\n"

        let pass = enableError == nil && disableError == nil && plistExists && plistGone
        out += "login.result: \(pass ? "PASS" : "FAIL")\n"
        FileHandle.standardError.write(Data(out.utf8))
        NSApp.terminate(nil)
    }

    /// Opens the dropdown's contents in an ordinary window.
    ///
    /// A `MenuBarExtra` panel only appears when its status item is clicked, which
    /// needs Accessibility permission to automate. This gives a way to see and
    /// screenshot the dropdown while developing without granting that.
    private func showPreviewWindow() {
        let hosting = NSHostingController(rootView: DropdownView(monitor: FanMonitor.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Mac Fan Speed — dropdown preview"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 300, height: 620))
        window.center()
        // Float it so it stays visible for screenshots even when another app
        // has focus, which is how it is usually inspected.
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        previewWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quitting with fans still forced is what SPEC.md safety rule 2 forbids.
        FanMonitor.shared.releaseFansForShutdown()
        FanMonitor.shared.stop()
    }

    /// Headless self-check, for CI and for verifying without a display.
    ///
    /// Waits long enough for the poll loop to produce real readings, then reports
    /// the status item, the activation policy and the values behind the menu bar
    /// label, so the output can be compared against `fanctl` directly.
    private func runSelfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let windows = NSApp.windows.map { String(describing: type(of: $0)) }
            let hasStatusItem = windows.contains { $0.contains("StatusBar") }
            let isAgent = NSApp.activationPolicy() == .accessory

            let monitor = FanMonitor.shared
            let gotReadings = monitor.cpu != nil || monitor.hasFans
            let collectedSamples = monitor.samples.count >= 2

            var out = ""
            out += "selftest.statusItem: \(hasStatusItem ? "PRESENT" : "MISSING")\n"
            out += "selftest.activationPolicy: \(isAgent ? "accessory (no Dock icon)" : "regular")\n"
            out += "selftest.readings: \(gotReadings ? "OK" : "NONE")\n"
            out += "selftest.polling: \(collectedSamples ? "OK" : "STALLED")\n"
            out += "selftest.detail: \(monitor.selftestSummary)\n"
            monitor.settings.refreshLoginItemState()
            out += "selftest.loginItem: \(monitor.settings.loginItemState)\n"
            out += "selftest.helper: \(monitor.helper.status)\n"
            out += "selftest.bundle: \(Bundle.main.bundlePath)\n"
            if let error = monitor.startupError {
                out += "selftest.startupError: \(error)\n"
            }

            let pass = hasStatusItem && isAgent && gotReadings && collectedSamples
            out += "selftest.result: \(pass ? "PASS" : "FAIL")\n"
            FileHandle.standardError.write(Data(out.utf8))

            NSApp.terminate(nil)
        }
    }
}
