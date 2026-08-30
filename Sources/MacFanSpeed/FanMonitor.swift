import Foundation
import SwiftUI
import SMCKit

public enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    public var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }

    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }
}

/// Polls the SMC and temperature sensors, keeps a rolling history, drives manual
/// control through the privileged helper, and formats everything the UI shows.
///
/// This type never writes to the SMC itself — every change goes through
/// `HelperClient` to the daemon, which re-validates it.
@MainActor
final class FanMonitor: ObservableObject {

    /// One reading. Values are optional because sensors can be unavailable, and
    /// the UI must show that honestly rather than substituting a zero.
    struct Sample: Identifiable {
        let time: Date
        let celsius: Double?
        let averageRPM: Double?
        var id: Date { time }
    }

    enum ControlMode: String { case auto, manual }

    static let shared = FanMonitor()

    static let pollInterval: TimeInterval = 2

    /// Enough samples for the longest range the charts offer, so switching to a
    /// wider window shows real history rather than starting from empty.
    /// 6 hours at one sample every 2 s is 10,800 entries — roughly half a
    /// megabyte, which is worth it to make the range buttons instant.
    static var historyLimit: Int {
        HistoryRange.maximumMinutes * 60 / Int(pollInterval)
    }

    // MARK: Published state

    @Published private(set) var fans: [Fan] = []
    @Published private(set) var cpu: TemperatureSensor?
    /// Every sensor the machine exposes, for the Sensors view.
    @Published private(set) var allSensors: [TemperatureSensor] = []
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var startupError: String?

    /// Stored rather than computed from settings: a computed property has to
    /// announce its own change, and one that forgets leaves the UI stale.
    @Published var historyRange: HistoryRange = .tenMinutes {
        didSet { settings.historyMinutes = historyRange.rawValue }
    }

    @Published private(set) var mode: ControlMode = .auto
    /// Which preset is active, or nil when the speed was set by hand.
    @Published private(set) var activePresetID: UUID?
    @Published private(set) var failsafeMessage: String?
    @Published private(set) var lastControlError: String?

    let settings = AppSettings()
    let presets = PresetStore()
    let helper = HelperClient()
    let installer = HelperInstaller()

    private var failsafe = Failsafe()
    private var monitor: SystemMonitor?
    private var timer: Timer?
    private var hasRestoredStartupMode = false

    /// SMC and sensor reads happen off the main thread so a slow read can never
    /// stutter the menu bar. The queue is serial, so the SMC connection is only
    /// ever touched by one thread.
    private let pollQueue = DispatchQueue(
        label: "io.github.bradr23.MacFanSpeed.poll", qos: .utility
    )

    private init() {
        // Property observers do not fire during initialisation, so this restores
        // the saved range without writing it straight back.
        historyRange = HistoryRange.from(minutes: settings.historyMinutes)
    }

    // MARK: Settings passthrough

    var unit: TemperatureUnit {
        get { settings.unit }
        set { settings.unit = newValue; objectWillChange.send() }
    }

    var linkFans: Bool {
        get { settings.linkFans }
        set { settings.linkFans = newValue; objectWillChange.send() }
    }

    // MARK: Lifecycle

    func start() {
        do {
            monitor = try SystemMonitor()
        } catch let error as SMCError {
            startupError = error.description
            return
        } catch {
            startupError = "\(error)"
            return
        }

        settings.refreshLoginItemState()
        helper.refreshStatus()

        poll()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Keep polling while a menu is tracking, otherwise the readings freeze
        // for as long as the dropdown is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let monitor else { return }
        pollQueue.async { [weak self] in
            let snapshot = monitor.snapshot()
            Task { @MainActor in self?.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        fans = snapshot.fans
        cpu = snapshot.cpuTemperature
        allSensors = snapshot.sensors

        // A daemon that stopped answering blocks every control path, so keep
        // testing it rather than waiting for someone to press "Re-check".
        helper.retryIfUnreachable()

        restoreStartupModeIfNeeded()
        // Last, so nothing in this tick can re-enable manual behind its back.
        evaluateFailsafe(celsius: snapshot.cpuTemperature?.celsius)

        // Re-send targets every poll. This doubles as the heartbeat that keeps
        // the daemon's watchdog from handing the fans back.
        if mode == .manual { sendTargets() }

        samples.append(
            Sample(
                time: Date(),
                celsius: snapshot.cpuTemperature?.celsius,
                averageRPM: snapshot.averageRPM
            )
        )
        if samples.count > Self.historyLimit {
            samples.removeFirst(samples.count - Self.historyLimit)
        }
    }

    /// Reapply whatever was in force when the app last quit.
    ///
    /// Deferred until the fans and the helper are both known, so a machine that
    /// reboots into a preset needs nobody to click anything.
    private func restoreStartupModeIfNeeded() {
        guard !hasRestoredStartupMode, !fans.isEmpty else { return }
        // The daemon may still be starting; waiting beats declaring failure.
        guard helper.status.isReady || settings.startupMode == .auto else { return }
        hasRestoredStartupMode = true

        switch settings.startupMode {
        case .auto:
            break
        case .manual:
            setMode(.manual)
        case .preset:
            if let preset = presets.preset(id: settings.selectedPresetID) {
                apply(preset: preset)
            } else {
                setMode(.manual)
            }
        }
    }

    // MARK: Control

    var currentPercent: Double { settings.manualPercent }

    /// Samples inside the selected window.
    var visibleSamples: [Sample] {
        samples.filter { $0.time >= historyWindowStart }
    }

    /// Oldest instant the charts should show. Also the left edge of the x-axis,
    /// so the window is visible even before there is enough history to fill it.
    var historyWindowStart: Date {
        Date().addingTimeInterval(-Double(historyRange.rawValue) * 60)
    }

    /// Speed for one fan, as a fraction of its range. With fans linked they all
    /// share one value; unlinked, each keeps its own.
    func percent(for fan: Fan) -> Double {
        guard !settings.linkFans else { return settings.manualPercent }
        return settings.perFanPercent["\(fan.index)"] ?? settings.manualPercent
    }

    func setMode(_ newMode: ControlMode) {
        lastControlError = nil

        switch newMode {
        case .manual:
            // The failsafe outranks every route into manual control. Without this
            // the deferred startup restore could re-enable manual while the
            // machine was still too hot, which is exactly what it did.
            guard !failsafe.isTripped else {
                lastControlError = "Too hot for manual control right now."
                return
            }
            guard helper.status.isReady else {
                lastControlError = "Install the fan control helper in Settings first."
                return
            }
            mode = .manual
            settings.startupMode = activePresetID == nil ? .manual : .preset
            sendTargets()

        case .auto:
            mode = .auto
            activePresetID = nil
            failsafeMessage = nil
            settings.startupMode = .auto
            helper.setAllAuto { [weak self] error in
                if let error { self?.lastControlError = error }
            }
        }
    }

    /// Take manual control at the current slider speed, following no preset.
    ///
    /// `setMode(.manual)` alone would leave any active preset selected, so the
    /// Custom button would appear to do nothing while a preset was in force.
    func setCustom() {
        let previousPreset = activePresetID
        activePresetID = nil
        settings.selectedPresetID = nil

        setMode(.manual)

        // setMode refuses while the failsafe holds or the helper is missing.
        // Put the preset back rather than leaving a selection the user can see
        // but never asked for.
        if mode != .manual {
            activePresetID = previousPreset
            settings.selectedPresetID = previousPreset
        }
    }

    func apply(preset: FanPreset) {
        settings.manualPercent = preset.percent
        // A preset is a single speed for the machine, so it overrides any
        // per-fan values rather than applying on top of them.
        settings.perFanPercent = [:]
        settings.selectedPresetID = preset.id
        activePresetID = preset.id
        settings.startupMode = .preset

        // Remember the choice either way, but do not act on it while the
        // failsafe holds; it resumes on its own once the machine cools.
        guard !failsafe.isTripped else {
            lastControlError = "Too hot for manual control right now."
            return
        }
        guard helper.status.isReady else {
            lastControlError = "Install the fan control helper in Settings first."
            return
        }
        mode = .manual
        sendTargets()
    }

    /// Set the speed by hand, which detaches from any active preset.
    ///
    /// - Parameter fanIndex: nil sets every fan, which is what the linked slider
    ///   does. A specific index sets one fan and is only reachable with fans
    ///   unlinked.
    func setPercent(_ percent: Double, fanIndex: Int? = nil) {
        let clamped = min(max(percent, 0), 1)

        if let fanIndex, !settings.linkFans {
            settings.perFanPercent["\(fanIndex)"] = clamped
        } else {
            settings.manualPercent = clamped
            // Linked means linked: drop the per-fan values so they cannot
            // reappear stale the next time the fans are unlinked.
            settings.perFanPercent = [:]
        }

        activePresetID = nil
        if mode == .manual {
            settings.startupMode = .manual
            sendTargets()
        }
        objectWillChange.send()
    }

    /// Resolved target for one fan, from that fan's current percentage.
    func target(for fan: Fan) -> Double { fan.rpm(forPercent: percent(for: fan)) }

    private func sendTargets() {
        guard mode == .manual, helper.status.isReady else { return }
        for fan in fans {
            helper.setFan(index: fan.index, rpm: target(for: fan)) { [weak self] error in
                // Clear on success as well as setting on failure: a transient
                // error used to stay on screen indefinitely once shown, long
                // after the fans were doing exactly what was asked.
                self?.lastControlError = error
            }
        }
    }

    // MARK: Failsafe

    private func evaluateFailsafe(celsius: Double?) {
        switch failsafe.evaluate(celsius: celsius, manualControlActive: mode == .manual) {
        case .noChange:
            break

        case .trip(let reason):
            // Give the fans back immediately, then report why. The stored startup
            // mode is deliberately left alone — the user's preference has not
            // changed, only the current safety state.
            mode = .auto
            failsafeMessage = reason.message
            helper.setAllAuto()

        case .release:
            failsafeMessage = nil
            // Resume whatever was in force before the machine got hot.
            if settings.startupMode != .auto, helper.status.isReady {
                mode = .manual
                sendTargets()
            }
        }
    }

    var isFailsafeTripped: Bool { failsafe.isTripped }

    /// Hand the fans back. Called on quit; blocking, because termination will
    /// not wait for an async reply.
    func releaseFansForShutdown() {
        guard mode == .manual else { return }
        helper.setAllAutoSynchronously()
    }

    // MARK: Formatting

    var hasFans: Bool { !fans.isEmpty }

    var averageRPM: Double? {
        guard !fans.isEmpty else { return nil }
        return fans.reduce(0) { $0 + $1.actualRPM } / Double(fans.count)
    }

    func temperatureString(_ celsius: Double?, includeSymbol: Bool = false) -> String {
        includeSymbol
            ? MenuBarFormatter.detailedTemperature(celsius, unit: unit)
            : MenuBarFormatter.temperature(celsius, unit: unit)
    }

    /// Readable name of whichever sensor is driving the reading, with the raw
    /// hardware name kept alongside so it stays traceable.
    var cpuSensorLabel: String {
        guard let cpu else { return "no sensor identified" }
        let named = SensorNaming.name(for: cpu)
        return named.isVerbatim ? named.raw : "\(named.display)  ·  \(named.raw)"
    }

    var menuBarText: String {
        MenuBarFormatter.label(
            celsius: cpu?.celsius,
            averageRPM: averageRPM,
            hasFans: hasFans,
            unit: unit
        )
    }

    /// Used by the headless self-check to prove real readings are flowing.
    var selftestSummary: String {
        let temp = cpu.map { String(format: "%.1f°C (%@)", $0.celsius, $0.name) } ?? "unavailable"
        let fanDesc = fans.isEmpty
            ? "none"
            : fans.map { String(format: "%.0f", $0.actualRPM) }.joined(separator: ", ")
        return "temp=\(temp) fans=[\(fanDesc)] samples=\(samples.count) label='\(menuBarText)'"
    }
}
