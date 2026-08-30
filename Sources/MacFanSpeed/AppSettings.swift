import Foundation
import ServiceManagement
import SMCKit

/// Everything the app remembers between launches.
///
/// Fan speeds are stored as **percentages**, never RPM, so a settings file that
/// moves to another Mac still means what it said. See `FanPreset`.
@MainActor
final class AppSettings: ObservableObject {

    enum StartupMode: String, Codable {
        case auto
        case manual
        case preset
    }

    // MARK: Stored settings

    @Published var unit: TemperatureUnit {
        didSet { defaults.set(unit.rawValue, forKey: Keys.unit) }
    }

    /// Mode to restore at launch, so a reboot lands back where the user left it.
    @Published var startupMode: StartupMode {
        didSet { defaults.set(startupMode.rawValue, forKey: Keys.startupMode) }
    }

    /// Manual speed as a fraction of each fan's range.
    @Published var manualPercent: Double {
        didSet { defaults.set(manualPercent, forKey: Keys.manualPercent) }
    }

    @Published var selectedPresetID: UUID? {
        didSet { defaults.set(selectedPresetID?.uuidString, forKey: Keys.selectedPreset) }
    }

    @Published var linkFans: Bool {
        didSet { defaults.set(linkFans, forKey: Keys.linkFans) }
    }

    /// Per-fan speeds, used only when `linkFans` is off. Keyed by fan index as a
    /// string because that is what a property list can store, and percentages
    /// rather than RPM for the same portability reason as everything else.
    @Published var perFanPercent: [String: Double] {
        didSet { defaults.set(perFanPercent, forKey: Keys.perFanPercent) }
    }

    /// How much history the charts show, in minutes.
    @Published var historyMinutes: Int {
        didSet { defaults.set(historyMinutes, forKey: Keys.historyMinutes) }
    }

    /// CPU temperature at which the fans go back to macOS.
    ///
    /// Settable **downward only**. The clamp here is one of four layers — the
    /// UI slider's range, this write, the read in `init`, and `Failsafe` itself,
    /// which clamps unconditionally and is the one the safety argument actually
    /// rests on. This layer is what catches a hand-edited preferences file or a
    /// `defaults write` from a script.
    @Published var safetyCutoffCelsius: Double {
        didSet {
            let clamped = Failsafe.clampTrip(safetyCutoffCelsius)
            // Assigning re-enters this observer, which then takes the else
            // branch and persists. Returning here avoids writing the unclamped
            // value first.
            if clamped != safetyCutoffCelsius {
                safetyCutoffCelsius = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.safetyCutoff)
        }
    }

    private enum Keys {
        static let unit = "temperatureUnit"
        static let startupMode = "startupMode"
        static let manualPercent = "manualPercent"
        static let selectedPreset = "selectedPresetID"
        static let linkFans = "linkFans"
        static let perFanPercent = "perFanPercent"
        static let historyMinutes = "historyMinutes"
        static let safetyCutoff = "safetyCutoffCelsius"
    }

    private let defaults: UserDefaults

    /// Injectable so tests can run against a scratch domain instead of the
    /// developer's live settings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        unit = defaults.string(forKey: Keys.unit)
            .flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
        startupMode = defaults.string(forKey: Keys.startupMode)
            .flatMap(StartupMode.init(rawValue:)) ?? .auto
        // Sanitised on read for the same reason as safetyCutoffCelsius below: a
        // hand-edited plist can hold NaN, and `max(.nan, floor)` is nan, so an
        // unchecked value here would silently defeat the thermal safety floor.
        let storedManual = defaults.object(forKey: Keys.manualPercent) as? Double ?? 0.35
        manualPercent = storedManual.isFinite ? min(max(storedManual, 0), 1) : 0.35
        selectedPresetID = (defaults.string(forKey: Keys.selectedPreset)).flatMap(UUID.init)
        linkFans = defaults.object(forKey: Keys.linkFans) as? Bool ?? true
        perFanPercent = (defaults.dictionary(forKey: Keys.perFanPercent) as? [String: Double] ?? [:])
            .compactMapValues { $0.isFinite ? min(max($0, 0), 1) : nil }
        historyMinutes = defaults.object(forKey: Keys.historyMinutes) as? Int
            ?? HistoryRange.defaultMinutes
        // Clamped on the way in as well as out: a value written by a different
        // build, or by hand, must not be able to raise the cutoff.
        safetyCutoffCelsius = Failsafe.clampTrip(
            defaults.object(forKey: Keys.safetyCutoff) as? Double ?? Failsafe.defaultTripCelsius
        )
    }

    // MARK: Launch at login

    enum LoginItemState: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable(String)

        var isEnabled: Bool { self == .enabled }
    }

    @Published private(set) var loginItemState: LoginItemState = .disabled

    func refreshLoginItemState() {
        if LoginItemManager.isUsingModernAPI, SMAppService.mainApp.status == .requiresApproval {
            loginItemState = .requiresApproval
            return
        }
        loginItemState = LoginItemManager.isEnabled ? .enabled : .disabled
    }

    /// - Returns: an error message, or nil on success.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        let error = LoginItemManager.setEnabled(enabled)
        refreshLoginItemState()
        return error
    }

    /// True when macOS's own login-item API is in use rather than the LaunchAgent
    /// fallback. Shown in Settings so the difference is not silent.
    var usesModernLoginAPI: Bool { LoginItemManager.isUsingModernAPI }

    /// Login items record the app's current path, so registering a copy that is
    /// about to move leaves a broken entry. Worth warning about rather than
    /// letting it silently fail after the user drags the app to Applications.
    var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix("\(NSHomeDirectory())/Applications/")
    }

    var bundlePath: String { Bundle.main.bundlePath }
}
