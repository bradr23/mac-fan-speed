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
    private var curveController = CurveController()
    private var monitor: SystemMonitor?
    private var timer: Timer?
    private var hasRestoredStartupMode = false
    /// When a snapshot last arrived. Feeds the stale-readings trip: a control
    /// loop that stops while the UI keeps showing its last comfortable value is
    /// a documented failure mode in this class of app.
    private var lastSnapshotAt: Date?

    /// The curve last handed to the controller, so an edit can be detected and
    /// applied immediately rather than waiting for the temperature to drift.
    private var lastAppliedCurve: FanCurve?

    /// What is currently deciding the fan speed, for the dropdown caption.
    @Published private(set) var speedDriver: SpeedDriver = .user
    /// The speed actually being commanded, after the curve, the safety floor and
    /// the rate limiter. Distinct from what the user asked for.
    @Published private(set) var commandedPercent: Double = 0

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

        // Checked here, on the main timer, and NOT inside apply(): if the poll
        // queue wedges, apply() never runs, so a staleness check living there
        // could never fire — which is exactly what it did. The whole point of
        // this rule is a control loop that has stopped while the UI keeps
        // showing its last comfortable reading.
        checkForStaleReadings()

        pollQueue.async { [weak self] in
            let snapshot = monitor.snapshot()
            Task { @MainActor in self?.apply(snapshot) }
        }
    }

    /// Hand the fans back if snapshots have stopped arriving.
    private func checkForStaleReadings() {
        guard mode == .manual, let last = lastSnapshotAt else { return }
        let age = Date().timeIntervalSince(last)
        guard age > Failsafe.staleReadingSeconds else { return }

        mode = .auto
        failsafeMessage = Failsafe.Reason.readingsStale(age).message
        releaseToAutomatic(reason: "stale readings")
    }

    /// Ask the daemon for automatic control and report if it refuses.
    ///
    /// The failsafe used to call `helper.setAllAuto()` with no completion, so a
    /// daemon that answered "I could not" was ignored while the UI stated the
    /// fans had been returned. The one moment the app most needs to be honest
    /// about failing is this one.
    private func releaseToAutomatic(reason: String) {
        helper.setAllAuto { [weak self] error in
            guard let self, let error else { return }
            self.lastControlError = "Could not return the fans to macOS (\(reason)): \(error)"
        }
    }

    private func apply(_ snapshot: SystemSnapshot) {
        fans = snapshot.fans
        cpu = snapshot.cpuTemperature
        allSensors = snapshot.sensors
        lastSnapshotAt = Date()

        // A daemon that stopped answering blocks every control path, so keep
        // testing it rather than waiting for someone to press "Re-check".
        helper.retryIfUnreachable()

        restoreStartupModeIfNeeded()
        // Last, so nothing in this tick can re-enable manual behind its back.
        evaluateFailsafe(snapshot: snapshot)

        // Re-send targets every poll. This doubles as the heartbeat that keeps
        // the daemon's watchdog from handing the fans back.
        //
        // The curve is recomputed inside this gate rather than before it, so it
        // inherits the failsafe's answer by construction instead of needing its
        // own check that could drift out of step.
        if mode == .manual {
            recomputeCommandedSpeed(rawCelsius: snapshot.cpuTemperature?.celsius)
            sendTargets()
        }

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

    /// What the user asked for, as a fraction of the fan's range — the slider
    /// position, not what is actually being commanded. With fans linked they all
    /// share one value; unlinked, each keeps its own.
    ///
    /// A curve profile has no per-fan notion: it is one machine-wide intent, the
    /// same way a preset already is.
    func requestedPercent(for fan: Fan) -> Double {
        if let preset = presets.preset(id: activePresetID), preset.curve != nil {
            return commandedPercent
        }
        guard !settings.linkFans else { return settings.manualPercent }
        return settings.perFanPercent["\(fan.index)"] ?? settings.manualPercent
    }

    /// What will actually be sent: the user's request raised to the safety floor
    /// if the machine is hot, then rate-limited.
    ///
    /// The two are deliberately separate. The slider keeps showing the user's
    /// intent even while the guard is overriding it, so their setting is never
    /// silently rewritten.
    func commandedPercent(for fan: Fan) -> Double {
        guard !settings.linkFans, activeCurve == nil,
              let stored = settings.perFanPercent["\(fan.index)"]
        else { return commandedPercent }
        // Unlinked fixed profiles keep independent speeds, each floored
        // separately against the same guard.
        return max(stored, ThermalGuard.percent(atCelsius: curveController.filteredCelsius))
    }

    /// Curve of the active profile, if it has one.
    var activeCurve: FanCurve? { presets.preset(id: activePresetID)?.curve }

    /// Start (or restart) the control loop from a clean slate.
    ///
    /// Called wherever continuity breaks — entering manual, switching profile,
    /// moving the slider, the failsafe releasing — so a reference temperature
    /// from before the gap cannot govern the first commit after it, and so a
    /// deliberate user action takes effect at once instead of being rate-limited
    /// into looking broken.
    private func beginControl() {
        lastAppliedCurve = nil
        curveController.reset(to: activeCurve == nil ? settings.manualPercent : 0)
        recomputeCommandedSpeed(rawCelsius: cpu?.celsius, immediate: true)
    }

    /// Recompute what to command, from the profile (or flat speed) and the
    /// safety floor.
    private func recomputeCommandedSpeed(rawCelsius: Double?, immediate: Bool = false) {
        let curve = activeCurve
        let requested = curve == nil ? settings.manualPercent : 0

        // Editing a curve has to take effect now. The deadband only commits a
        // new value once the *temperature* has moved past it, so an edit made
        // while the machine sat at a steady temperature did nothing at all —
        // sometimes for minutes — and looked like the editor was broken.
        let curveChanged = curve != lastAppliedCurve
        lastAppliedCurve = curve

        commandedPercent = curveController.step(
            requested: requested,
            curve: curve,
            rawCelsius: rawCelsius,
            now: Date(),
            immediate: immediate || curveChanged
        )
        speedDriver = curveController.driver
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
            beginControl()
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
        beginControl()
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
            // Immediate: dragging the slider has to move the fans now, not over
            // the next half minute the rate limiter would otherwise impose.
            beginControl()
            sendTargets()
        }
        objectWillChange.send()
    }

    /// Resolved target for one fan: what is actually commanded, not what was
    /// asked for.
    func target(for fan: Fan) -> Double { fan.rpm(forPercent: commandedPercent(for: fan)) }

    private func sendTargets() {
        guard mode == .manual, helper.status.isReady else { return }
        let batch = controllableFans
        guard !batch.isEmpty else { return }

        // Collected across the whole round rather than assigned per fan. Each
        // reply used to overwrite the last, so on a multi-fan Mac one fan's
        // success erased another fan's failure and the user saw nothing wrong —
        // which would have hidden the refusal a fan with unreadable limits now
        // produces. The report is published once every fan has answered.
        var errors: [Int: String] = [:]
        var replies = 0

        for fan in batch {
            helper.setFan(index: fan.index, rpm: target(for: fan)) { [weak self] error in
                guard let self else { return }
                replies += 1
                if let error { errors[fan.index] = error }
                guard replies == batch.count else { return }

                // Clearing on an all-clear round matters as much as reporting:
                // a transient error used to stay on screen indefinitely, long
                // after the fans were doing exactly what was asked.
                self.lastControlError = errors.isEmpty ? nil : errors
                    .sorted { $0.key < $1.key }
                    .map { batch.count > 1 ? "Fan \($0.key + 1): \($0.value)" : $0.value }
                    .joined(separator: "  ")
            }
        }
    }

    // MARK: Failsafe

    /// Hottest reading among the sensors the CPU failsafe deliberately excludes.
    ///
    /// `Temperature.swift` keeps battery and storage out of the CPU figure,
    /// which is right as a definition of *CPU* temperature — but it also meant
    /// nothing watched them at all. A laptop pinned to a low fan speed can cook
    /// its battery long before the die reaches the cutoff: lithium-ion degrades
    /// above roughly 45–60 °C, some 40 °C below the CPU trip.
    private func hottest(_ snapshot: SystemSnapshot, matching fragments: [String]) -> Double? {
        snapshot.sensors
            .filter { sensor in
                let name = sensor.name.lowercased()
                return fragments.contains { name.contains($0) }
            }
            .map(\.celsius)
            .filter { $0.isFinite && $0 > -50 && $0 < 200 }
            .max()
    }

    private func evaluateFailsafe(snapshot: SystemSnapshot) {
        // One place the user's setting enters the safety path, so it cannot go
        // stale. Clamped again inside, whatever arrives.
        failsafe.setTrip(settings.safetyCutoffCelsius)

        // Zero by construction here — apply() has just stamped the timestamp.
        // Staleness is judged in poll(), where a wedged queue cannot hide it.
        let age: TimeInterval = 0
        let input = FailsafeInput(
            cpuCelsius: snapshot.cpuTemperature?.celsius,
            hottestBatteryCelsius: hottest(snapshot, matching: ["batt", "gas gauge"]),
            hottestStorageCelsius: hottest(snapshot, matching: ["nand", "ssd"]),
            thermalState: ProcessInfo.processInfo.thermalState,
            readingAge: age,
            now: Date(),
            manualControlActive: mode == .manual
        )

        switch failsafe.evaluate(input) {
        case .noChange:
            break

        case .trip(let reason):
            // Give the fans back immediately, then report why. The stored startup
            // mode is deliberately left alone — the user's preference has not
            // changed, only the current safety state.
            mode = .auto
            failsafeMessage = reason.message
            releaseToAutomatic(reason: "failsafe")

        case .release:
            failsafeMessage = nil
            // Resume whatever was in force before the machine got hot.
            if settings.startupMode != .auto, helper.status.isReady {
                mode = .manual
                beginControl()
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

    /// Fans the daemon will actually accept a target for. A fan whose limits the
    /// SMC never reported is shown and monitored, but never driven.
    var controllableFans: [Fan] { fans.filter(\.limitsReported) }
    var hasControllableFans: Bool { !controllableFans.isEmpty }

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
