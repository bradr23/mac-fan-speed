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

    private enum Keys {
        static let unit = "temperatureUnit"
        static let startupMode = "startupMode"
        static let manualPercent = "manualPercent"
        static let selectedPreset = "selectedPresetID"
        static let linkFans = "linkFans"
        static let perFanPercent = "perFanPercent"
        static let historyMinutes = "historyMinutes"
    }

    private let defaults = UserDefaults.standard

    init() {
        unit = defaults.string(forKey: Keys.unit)
            .flatMap(TemperatureUnit.init(rawValue:)) ?? .celsius
        startupMode = defaults.string(forKey: Keys.startupMode)
            .flatMap(StartupMode.init(rawValue:)) ?? .auto
        manualPercent = defaults.object(forKey: Keys.manualPercent) as? Double ?? 0.35
        selectedPresetID = (defaults.string(forKey: Keys.selectedPreset)).flatMap(UUID.init)
        linkFans = defaults.object(forKey: Keys.linkFans) as? Bool ?? true
        perFanPercent = defaults.dictionary(forKey: Keys.perFanPercent) as? [String: Double] ?? [:]
        historyMinutes = defaults.object(forKey: Keys.historyMinutes) as? Int
            ?? HistoryRange.defaultMinutes
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
