import AppKit
import SwiftUI
import SMCKit

@main
struct MacFanSpeedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            DropdownView(monitor: .shared)
        } label: {
            MenuBarTitle(label: FanMonitor.shared.menuBarLabel)
        }
        // Charts and controls need a real window; the default .menu style only
        // renders native menu items.
        .menuBarExtraStyle(.window)
    }
}

/// The scene deliberately does not observe `FanMonitor`.
///
/// It used to, through an `@StateObject`, which meant the whole scene — label
/// included — was rebuilt on every poll, four times over, because each of
/// `fans`, `cpu`, `allSensors` and `samples` publishes separately. The label
/// observes a one-property object that changes only when the text does, and the
/// dropdown observes the monitor itself but is only built while it is open.
/// `FanMonitor.shared` is a singleton that owns its own lifetime, so nothing
/// here needs to keep it alive.
private struct MenuBarTitle: View {
    @ObservedObject var label: MenuBarLabel

    var body: some View {
        Text(label.text).monospacedDigit()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !terminateIfAlreadyRunning() else { return }

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
        if ProcessInfo.processInfo.environment["MFS_TEST_GUARD"] != nil {
            runGuardTest()
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

    /// Quit immediately if another copy is already running.
    ///
    /// Two instances is not hypothetical. The login item launches the app by
    /// path, so a copy left in Downloads and a copy in Applications are distinct
    /// as far as LaunchServices is concerned and both will start. The result is
    /// two menu bar icons and, worse, two controllers driving the same daemon:
    /// one sends its target every two seconds while the other tries to release
    /// the fans, so quitting one appears to do nothing.
    ///
    /// The environment check keeps the test entry points usable, since those are
    /// deliberately run alongside a normal copy of the app.
    private func terminateIfAlreadyRunning() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let isTestRun = environment.keys.contains { $0.hasPrefix("MFS_") }
        guard !isTestRun, let identifier = Bundle.main.bundleIdentifier else { return false }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ourPID }
        guard let existing = others.first else { return false }

        let message = "MacFanSpeed: already running as pid "
            + "\(existing.processIdentifier); this copy is exiting.\n"
        FileHandle.standardError.write(Data(message.utf8))
        NSApp.terminate(nil)
        return true
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
            // Printed so the harness can prove it is driving the binary it
            // thinks it is. A failed rebuild used to leave the previous build in
            // place with the real 95 °C ceiling, and the script then reported
            // "failsafe did not fire" as a product failure.
            out += "manualtest.tripCelsius: \(Int(monitor.settings.safetyCutoffCelsius))\n"
            FileHandle.standardError.write(Data(out.utf8))

            monitor.setPercent(percent)
            monitor.setMode(.manual)

            // Give the firmware time to yield and the fans time to spin up.
            var ticks = 0
            var sawFailsafe = false
            var trips = 0
            var wasAuto = false
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
              // Scheduled on the main run loop, so this always fires on main.
              MainActor.assumeIsolated {
                ticks += 1
                let rpm = monitor.fans.map { Int($0.actualRPM) }
                var line = "manualtest.t+\(ticks * 3)s rpm=\(rpm) mode=\(monitor.mode.rawValue)"
                let isAuto = monitor.mode == .auto
                if isAuto {
                    sawFailsafe = true
                    if !wasAuto { trips += 1 }
                }
                wasAuto = isAuto
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
                // A correct failsafe trips once and stays tripped until the
                // machine is genuinely cool. Counting the transitions turns
                // flapping — which used to be invisible in this output — into
                // something the harness can fail on.
                summary += "manualtest.tripCount: \(trips)\n"
                summary += "manualtest.finalMode: \(monitor.mode.rawValue)\n"
                summary += "manualtest.result: \(peak > want * 0.75 ? "PASS" : "FAIL")\n"
                summary += "manualtest.quitting — the shutdown path must release the fans\n"
                FileHandle.standardError.write(Data(summary.utf8))
                NSApp.terminate(nil)
              }
            }
        }
    }

    /// Walk a temperature ramp through the real controller and print what it
    /// would command, without heating anything.
    ///
    /// The escalation path is the one part of this app that matters most and is
    /// hardest to exercise honestly: reproducing it for real means driving a Mac
    /// to 90 °C with its fans pinned low, which is exactly the situation the code
    /// exists to prevent. This runs the shipping `CurveController` — the same
    /// filter, deadband and rate limiter — against a synthetic ramp instead.
    private func runGuardTest() {
        // Deferred like the other hooks so the first poll has produced fan
        // readings; without them the rpm column is the interesting part missing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.reportGuardRamp() }
    }

    private func reportGuardRamp() {
        var out = "guardtest.fans: \(FanMonitor.shared.fans.count)\n"
        let fan = FanMonitor.shared.fans.first
        let requested = 0.15
        out += "guardtest.requested: \(Int(requested * 100))%"
            + (fan.map { " (\(Int($0.rpm(forPercent: requested))) rpm)" } ?? "") + "\n"
        out += "guardtest.cutoff: \(Int(FanMonitor.shared.settings.safetyCutoffCelsius)) °C\n"
        out += "  °C   requested  commanded  rpm      driver\n"

        var controller = CurveController()
        controller.reset(to: requested)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var tick = 0

        for celsius in stride(from: 40.0, through: 94.0, by: 2.0) {
            // Hold each step long enough for the filter and rate limiter to
            // settle, so the printed value is the steady state rather than a
            // point on a ramp.
            var commanded = 0.0
            for _ in 0..<25 {
                clock = clock.addingTimeInterval(FanMonitor.pollInterval)
                tick += 1
                commanded = controller.step(
                    requested: requested, curve: nil, rawCelsius: celsius, now: clock
                )
            }
            let rpm = fan.map { String(Int($0.rpm(forPercent: commanded))) } ?? "—"
            let driver: String
            switch controller.driver {
            case .user: driver = "user"
            case .profileCurve: driver = "curve"
            case .thermalGuard: driver = "GUARD"
            }
            let pad = { (text: String, width: Int) -> String in
                text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0)
            }
            out += pad(String(Int(celsius)), 5) + pad("\(Int(requested * 100))%", 11)
                + pad("\(Int(commanded * 100))%", 11) + pad(rpm, 9) + driver + "\n"
        }

        // The property that matters: the floor may only ever raise a speed.
        var everLowered = false
        var controller2 = CurveController()
        controller2.reset(to: requested)
        var clock2 = Date(timeIntervalSince1970: 2_000_000)
        for celsius in stride(from: 30.0, through: 94.0, by: 1.0) {
            for _ in 0..<15 {
                clock2 = clock2.addingTimeInterval(FanMonitor.pollInterval)
                let value = controller2.step(
                    requested: requested, curve: nil, rawCelsius: celsius, now: clock2
                )
                if value < requested - 0.001 { everLowered = true }
            }
        }
        out += "guardtest.neverLoweredBelowRequest: \(!everLowered)\n"
        out += "guardtest.result: \(everLowered ? "FAIL" : "PASS")\n"

        FileHandle.standardError.write(Data(out.utf8))
        NSApp.terminate(nil)
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
            out += "selftest.replacedWhileRunning: "
                + "\(AppCodeIdentity.wasReplacedWhileRunning)\n"
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
