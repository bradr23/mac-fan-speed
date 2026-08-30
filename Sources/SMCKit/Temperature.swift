import Foundation
import CIOHIDShim

/// How confident we are that a sensor reflects CPU die temperature.
///
/// Sensor names differ across chip generations and variants, and no single list
/// can be complete for hardware that does not exist yet. Rather than guessing,
/// sensors are sorted into tiers and the best available tier wins.
public enum SensorTier: Int, Comparable, CustomStringConvertible, Sendable {
    /// Per-core cluster sensors (`pACC`/`eACC`). Documented for M-series, but
    /// absent entirely on some hardware — an M4 Pro (Mac16,8) exposes none.
    case coreCluster = 1
    /// Whole-SoC or PMU die sensors. This is what an M4 Pro actually provides
    /// (`PMU tdie1`–`tdie14`), so tier 2 is a normal outcome, not a degraded one.
    case socDie = 2
    /// Not identifiable as CPU, but not a known non-CPU sensor either.
    case unclassified = 3
    /// Known not to be a CPU sensor (battery, storage, ambient...).
    case excluded = 4

    public static func < (a: SensorTier, b: SensorTier) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .coreCluster:  return "core-cluster"
        case .socDie:       return "soc-die"
        case .unclassified: return "unclassified"
        case .excluded:     return "excluded"
        }
    }
}

public struct TemperatureSensor: Sendable {
    /// The name the hardware reports, e.g. `PMU tdie1`.
    public let name: String
    public let celsius: Double
    public let tier: SensorTier
    /// SMC key backing this sensor, e.g. `TP1b`. Nil when unavailable.
    public let smcKey: String?

    public init(name: String, celsius: Double, tier: SensorTier, smcKey: String? = nil) {
        self.name = name
        self.celsius = celsius
        self.tier = tier
        self.smcKey = smcKey
    }
}

/// Reads Apple Silicon temperature sensors through IOKit's HID event system.
///
/// All failures are reported as "no readings" rather than thrown: losing sensors
/// is an expected state that the failsafe reacts to, not an error to crash on.
public final class TemperatureReader: @unchecked Sendable {

    /// Name fragments that identify CPU sensors, most specific tier first.
    /// Adding support for new hardware should mean adding a string here.
    ///
    /// Two naming schemes exist and both must be covered. M1 and M2 expose a
    /// named family (`pACC MTR Temp Sensor0`, `eACC…`, `SOC MTR…`,
    /// `PMGR SOC Die Temp Sensor…`). M4 and later expose only generic die
    /// sensors (`PMU tdie1`, and on multi-die parts `PMU2 tdie1`). Where exactly
    /// the change happened is not publicly documented, so neither scheme is
    /// assumed — whichever is present wins.
    private static let tierPatterns: [(tier: SensorTier, fragments: [String])] = [
        (.coreCluster, ["acc mtr temp"]),
        (.socDie, [
            "soc mtr temp", "soc mtr",
            "pmgr soc die",          // M1-era whole-SoC die sensor
            "tdie",                  // matches PMU tdie1 and PMU2 tdie1 alike
        ]),
    ]

    /// Sensors that must never feed the failsafe. Checked before the tiers
    /// above, so a fallback reading never silently reports something else as CPU.
    ///
    /// Two of these matter more than the obvious ones:
    ///
    /// - `tcal` is a static calibration constant, not a measurement. It reads
    ///   51.85 on every Apple Silicon machine regardless of load — about 15 °C
    ///   above the real die sensors on an idle M4 Pro. Treating it as a CPU
    ///   reading would inflate every value and could trip the failsafe early.
    /// - `tdev` reads garbage: about −21.7 on M1 and around −9201 on M4 Pro.
    ///   The plausible-range check below happens to drop both, but −21.7 sits
    ///   barely outside it, so hardware reporting a merely *odd* value rather
    ///   than an absurd one would slip through and corrupt the failsafe's input.
    ///   Excluding the family by name does not rely on the range check.
    ///
    /// Exclusion here only affects what the failsafe watches. These sensors are
    /// still listed in the Sensors view — see `SensorCategory`.
    private static let excludedFragments = [
        "batt", "nand", "charger", "ambient", "gas gauge",
        "tcal", "tdev", "display", "airport", "wifi", "camera", "speaker",
    ]

    /// Sensor names that are not real readings.
    private static let ignoredNames: Set<String> = ["noname", ""]

    private var client: CIOHIDEventSystemClientRef?

    /// The HID client is not safe to drive from two threads at once.
    private let lock = NSLock()

    public init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)

        guard let client else { return }
        let matching: [String: Any] = [
            "PrimaryUsagePage": kCIOHIDPageAppleVendor,
            "PrimaryUsage": kCIOHIDUsageAppleVendorTemperatureSensor,
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
    }

    deinit {
        CIOHIDReleaseClient(client)
    }

    /// True when the sensor interface is usable at all.
    public var isAvailable: Bool { client != nil }

    private static func fourCharCode(_ value: UInt32) -> String? {
        let bytes = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func classify(_ name: String) -> SensorTier {
        let lower = name.lowercased()
        if excludedFragments.contains(where: lower.contains) { return .excluded }
        for entry in tierPatterns where entry.fragments.contains(where: lower.contains) {
            return entry.tier
        }
        return .unclassified
    }

    /// Every temperature sensor currently readable, with its classification.
    public func readAll() -> [TemperatureSensor] {
        lock.lock()
        defer { lock.unlock() }

        guard let client,
              let services = IOHIDEventSystemClientCopyServices(client)
        else { return [] }

        var sensors: [TemperatureSensor] = []
        let count = CFArrayGetCount(services)

        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = CIOHIDServiceClientRef(raw)

            var nameBuffer = [CChar](repeating: 0, count: 256)
            guard CIOHIDCopySensorName(service, &nameBuffer, 256) == 1 else { continue }
            let name = String(cString: nameBuffer)

            var celsius: Double = 0
            guard CIOHIDReadTemperature(service, &celsius) == 1 else { continue }

            // Services with no usable name are skipped above; this catches the
            // placeholder text some dumping tools substitute for a NULL product
            // name, in case it ever arrives as a real string.
            guard !Self.ignoredNames.contains(name.lowercased()) else { continue }

            // Readings outside this range mean the sensor is not reporting a real
            // die temperature; including them would corrupt the hottest-CPU value.
            guard celsius > -20, celsius < 150 else { continue }

            let keyCode = CIOHIDCopySensorKey(service)
            let smcKey = keyCode == 0 ? nil : Self.fourCharCode(keyCode)

            sensors.append(
                TemperatureSensor(
                    name: name,
                    celsius: celsius,
                    tier: Self.classify(name),
                    smcKey: smcKey
                )
            )
        }
        return sensors.sorted { $0.name < $1.name }
    }

    /// Hottest CPU temperature, using the most specific tier that matched.
    ///
    /// Returns nil when nothing usable was found. Callers must treat nil as
    /// "temperature unknown" — the failsafe forces fans back to automatic in
    /// that case rather than holding a manual speed blind.
    public func hottestCPU(from sensors: [TemperatureSensor]? = nil) -> TemperatureSensor? {
        let all = sensors ?? readAll()
        for tier in [SensorTier.coreCluster, .socDie, .unclassified] {
            let matches = all.filter { $0.tier == tier }
            if let hottest = matches.max(by: { $0.celsius < $1.celsius }) {
                return hottest
            }
        }
        return nil
    }
}
