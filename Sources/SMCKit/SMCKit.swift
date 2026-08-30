import Foundation

/// Shared SMC + sensor layer used by the app, the helper and the CLI.
public enum SMCKit {
    /// Project version. `scripts/release.sh` checks this against
    /// `CFBundleShortVersionString` in Info.plist, so the CLI and the daemon can
    /// never report a different version from the app they shipped with.
    public static let version = "0.3.0"
}

/// A single reading of everything the UI needs, taken together so the
/// temperature and fan values in one sample are consistent.
public struct SystemSnapshot: Sendable {
    public let fans: [Fan]
    public let cpuTemperature: TemperatureSensor?
    public let sensors: [TemperatureSensor]

    public init(
        fans: [Fan],
        cpuTemperature: TemperatureSensor?,
        sensors: [TemperatureSensor]
    ) {
        self.fans = fans
        self.cpuTemperature = cpuTemperature
        self.sensors = sensors
    }

    /// Average fan speed, or nil on fanless Macs.
    public var averageRPM: Double? {
        guard !fans.isEmpty else { return nil }
        return fans.reduce(0) { $0 + $1.actualRPM } / Double(fans.count)
    }

    public var hasFans: Bool { !fans.isEmpty }
}

/// Convenience façade over the SMC and sensor readers.
public final class SystemMonitor: @unchecked Sendable {
    private let smc: SMCConnection
    private let fanReader: FanReader
    private let temperatureReader: TemperatureReader

    public init() throws {
        smc = try SMCConnection()
        fanReader = FanReader(smc: smc)
        temperatureReader = TemperatureReader()
    }

    public var temperatureSensingAvailable: Bool { temperatureReader.isAvailable }

    public func snapshot() -> SystemSnapshot {
        let sensors = temperatureReader.readAll()
        return SystemSnapshot(
            fans: fanReader.readAll(),
            cpuTemperature: temperatureReader.hottestCPU(from: sensors),
            sensors: sensors
        )
    }

    public func fans() -> [Fan] { fanReader.readAll() }
    public func sensors() -> [TemperatureSensor] { temperatureReader.readAll() }
    public func hottestCPU() -> TemperatureSensor? { temperatureReader.hottestCPU() }

    /// Read a raw SMC key. For diagnostics only — the UI never uses this.
    public func rawKey(_ key: String) throws -> SMCKeyValue { try smc.read(key) }

    /// A controller sharing this monitor's SMC connection. Writing still
    /// requires root; the controller enforces that.
    public func makeController() -> FanController { FanController(smc: smc) }

    /// Every SMC key this machine exposes. Diagnostics only.
    public func allKeyNames() -> [String] { smc.allKeyNames() }
}
